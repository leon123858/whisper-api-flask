FROM python:3.10-slim

WORKDIR /python-docker

COPY requirements.txt requirements.txt
RUN apt-get update -q && apt-get install -qy git ffmpeg
RUN pip3 install -r requirements.txt
RUN python -c 'import whisper;whisper.load_model("large", device="cpu")'
COPY app.py app.py

EXPOSE 5000

CMD [ "gunicorn","-w1","-b 0.0.0.0:8000","-t","120","app"]
