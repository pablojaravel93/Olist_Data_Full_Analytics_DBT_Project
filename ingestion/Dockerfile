FROM python:3.13-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .

# Job mode: run the pipeline once and exit (non-zero exit = failed execution)
CMD ["python", "main.py"]
