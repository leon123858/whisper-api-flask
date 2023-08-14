FROM nvidia/cuda:12.2.0-base-ubuntu20.04

WORKDIR /python-docker

COPY requirements.txt requirements.txt
RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git ffmpeg python3-pip && \
 apt-get clean autoclean && apt-get autoremove --yes
RUN pip3 install -r requirements.txt
COPY app.py app.py

EXPOSE 8000

CMD [ "gunicorn","-w1","-b 0.0.0.0:8000","-t","600","app:app"]
