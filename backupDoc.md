Do you need to host your own instance of Whisper as an API for transcription? You can use GKE with GPU nodes to do this in Google Cloud easily. In this article, we’ll use GKE Autopilot to host a custom API written in Python, and serve the Whisper endpoint via a Kubernetes Ingress. I will assume that you already have a GKE Autopilot cluster created. If you don’t, see https://cloud.google.com/kubernetes-engine/docs/how-to/creating-an-autopilot-cluster for instructions on creating one.


Skip to the code: https://github.com/skeenan947/whisper-api-flask

First off, we need an app to deploy. This app presents a /whisper endpoint that you can POST a file to. It takes the upload, saves it to a temp file, and then uses the whisper python API to transcribe the file, returning the transcription as JSON. Please note that this code is copied from https://github.com/lablab-ai/whisper-api-flask/blob/main/app.py

from flask import Flask, abort, request
from flask_cors import CORS
from tempfile import NamedTemporaryFile
import whisper
import torch

# Check if NVIDIA GPU is available
torch.cuda.is_available()
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"

# Load the Whisper model:
model = whisper.load_model("large", device=DEVICE)

app = Flask(__name__)
CORS(app)

@app.route("/")
def root_handler():
    return "OK"

@app.route('/whisper', methods=['POST'])
def whisper_handler():
    if not request.files:
        # If the user didn't submit any files, return a 400 (Bad Request) error.
        abort(400)

    # For each file, let's store the results in a list of dictionaries.
    results = []

    # Loop over every file that the user submitted.
    for filename, handle in request.files.items():
        # Create a temporary file.
        # The location of the temporary file is available in `temp.name`.
        temp = NamedTemporaryFile()
        # Write the user's uploaded file to the temporary file.
        # The file will get deleted when it drops out of scope.
        handle.save(temp)
        # Let's get the transcript of the temporary file.
        result = model.transcribe(temp.name)
        # Now we can store the result object for this file.
        results.append({
            'filename': filename,
            'transcript': result['text'],
        })

    # This will be automatically converted to JSON.
    return {'results': results}
Now, let’s package this as a Docker image so that it can be deployed in Kubernetes. We’ll use gunicorn to serve the endpoint, rather than Flask’s built-in development server, as it’s a lot more scalable.

FROM nvidia/cuda:12.2.0-base-ubuntu20.04

WORKDIR /python-docker

COPY requirements.txt requirements.txt
RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install \
 -y --no-install-recommends git ffmpeg python3-pip && \
 apt-get clean autoclean && apt-get autoremove --yes
RUN pip3 install -r requirements.txt
# Preload model so that startup time isn't too slow
RUN python3 -c 'import whisper;whisper.load_model("large", device="cpu")'
COPY app.py app.py

EXPOSE 8000

CMD [ "gunicorn","-w1","-b 0.0.0.0:8000","-t","600","app:app"]
Next, let’s package this as a Kubernetes Deployment object. I’ll assume that you have already published the above docker image to a Docker registry. You’ll see below that mine is at skeenan947/whisper-api:latest. I also included a NodeSelector, which tells GKE to spin up a GPU instance for us
```
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app.kubernetes.io/name: whisper-api
  name: whisper-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/instance: whisper
      app.kubernetes.io/name: whisper-api
  template:
    metadata:
      labels:
        app.kubernetes.io/instance: whisper
        app.kubernetes.io/name: whisper-api
    spec:
      containers:
      - image: skeenan947/whisper-api:latest
        imagePullPolicy: Always
        livenessProbe:
          failureThreshold: 3
          httpGet:
            path: /
            port: http
            scheme: HTTP
          initialDelaySeconds: 600
          periodSeconds: 60
          successThreshold: 1
          timeoutSeconds: 1
        name: whisper-api
        ports:
        - containerPort: 8000
          name: http
          protocol: TCP
        readinessProbe:
          failureThreshold: 10
          httpGet:
            path: /
            port: http
            scheme: HTTP
          initialDelaySeconds: 120
          periodSeconds: 60
          successThreshold: 1
          timeoutSeconds: 1
        resources:
          limits:
            cpu: "4"
            ephemeral-storage: 1Gi
            memory: 24Gi
            nvidia.com/gpu: "1"
          requests:
            cpu: "4"
            ephemeral-storage: 1Gi
            memory: 24Gi
            # Request a GPU
            nvidia.com/gpu: "1"
      nodeSelector:
        # ask for a GPU node with a Tesla T4 on it
        cloud.google.com/gke-accelerator: nvidia-tesla-t4
        cloud.google.com/gke-accelerator-count: "1"
```

Deploying this to GKE will give us a working Whisper deployment, but we still need to deploy an Ingress in order to access it. This requires a Service object, an Ingress object, and a ManagedCertificate (for SSL). We also need a static IP reservation, which we’ll have to use gcloud to create first.

# Provision the IP
gcloud compute addresses create whisper --global
# Get the IP address (create a DNS A record pointing at this)
gcloud compute addresses describe whisper --global
```
apiVersion: v1
kind: Service
metadata:
  annotations:
    cloud.google.com/neg: '{"ingress":true}'
  labels:
    app.kubernetes.io/name: whisper-api
  name: whisper-api
spec:
  ports:
  - name: http
    port: 8000
    protocol: TCP
    targetPort: http
  selector:
    app.kubernetes.io/instance: whisper
    app.kubernetes.io/name: whisper-api
  sessionAffinity: None
  type: ClusterIP
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    cloud.google.com/neg: '{"exposed_ports": {"80":{"name": "whisper"}}}'
    kubernetes.io/ingress.class: gce
    kubernetes.io/ingress.global-static-ip-name: whisper
    networking.gke.io/managed-certificates: managed-cert
  labels:
    app.kubernetes.io/name: whisper-api
  name: whisper-api
spec:
  rules:
  - host: whisper.your-domain.com
    http:
      paths:
      - backend:
          service:
            name: whisper-api
            port:
              number: 8000
        path: /
        pathType: Prefix
  tls:
  - hosts:
    - whisper.your-domain.com
    secretName: whisper-tls
apiVersion: networking.gke.io/v1
kind: ManagedCertificate
metadata:
  name: managed-cert
spec:
  domains:
    - whisper.your-domain.com
```
It may take a couple of hours for the ManagedCertificate to provision properly. You’ll also need to create a DNS entry and point it to your IP address. As there are so many options for DNS, I’ll leave this part out.

At this point, you should be done! Send a curl to test.

curl -X POST -F 'file=@/Users/skeenan/Downloads/some_file.mp3' \
 https://whisper.your-domain.com/whisper

# If you want to test before the SSL cert is provisioned, you can:
kubectl port-forward svc/whisper-api 8000:8000
curl -X POST -F 'file=@/Users/skeenan/Downloads/km230802.mp3' \
 http://localhost:8000/whisper

# To see logs from your Whisper instance:
kubectl logs -l app.kubernetes.io/name=whisper-api
