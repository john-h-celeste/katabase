FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY *.py .
# Don't run as root inside the container
RUN useradd -r -u 10001 appuser
USER appuser
#EXPOSE 8000
CMD ["python", "ingest.py"]
