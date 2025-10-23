FROM python:3.12-slim

# Build arguments for version information
ARG APP_VERSION=unknown
ARG BUILD_COMMIT=unknown
ARG BUILD_DATE=unknown

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV DJANGO_SETTINGS_MODULE=homelab.settings
ENV APP_VERSION=${APP_VERSION}
ENV BUILD_COMMIT=${BUILD_COMMIT}
ENV BUILD_DATE=${BUILD_DATE}

# Set work directory
WORKDIR /app

# Install system dependencies
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy project
COPY . .

# Inject build information into version.py
RUN sed -i "s/BUILD_COMMIT = \"unknown\"/BUILD_COMMIT = \"${BUILD_COMMIT}\"/" version.py && \
    sed -i "s/BUILD_DATE = \"unknown\"/BUILD_DATE = \"${BUILD_DATE}\"/" version.py

# Create necessary directories
RUN mkdir -p /app/data

# Run database migrations and collect static files
RUN python manage.py migrate
RUN python manage.py collectstatic --noinput

# Create a non-root user
RUN adduser --disabled-password --gecos '' django
RUN chown -R django:django /app
USER django

# Expose port
EXPOSE 8000

# Add image labels with version metadata
LABEL org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${BUILD_COMMIT}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.title="Homelab Django Application" \
      org.opencontainers.image.description="Simple Django REST API for K3s homelab demo"

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:8000/api/health/ || exit 1

# Run the application
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "3", "--timeout", "120", "homelab.wsgi:application"]