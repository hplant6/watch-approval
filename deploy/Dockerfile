# Watch Approval relay — container image (works on arm64 Raspberry Pi and x86 Linux).
FROM python:3.12-slim

WORKDIR /app

# Runtime deps. aioapns pulls in cryptography/pyjwt/h2; prebuilt wheels exist for
# arm64 and x86_64 (use a 64-bit Pi OS so no compiler is needed).
RUN pip install --no-cache-dir \
    "fastapi>=0.139.0" \
    "uvicorn>=0.50.0" \
    "pydantic>=2.13.4" \
    "aioapns>=3.1"

COPY server/main.py ./

EXPOSE 8420
CMD ["python", "main.py"]
