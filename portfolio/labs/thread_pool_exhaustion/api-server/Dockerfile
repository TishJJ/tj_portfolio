FROM python:3.11-slim

RUN apt-get update && apt-get install -y \
    strace \
    curl \
    iproute2 \
    procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY app.py .

CMD ["gunicorn", "--workers", "1", "--threads", "10", "--timeout", "120", "-b", "0.0.0.0:5000", "app:app"]
