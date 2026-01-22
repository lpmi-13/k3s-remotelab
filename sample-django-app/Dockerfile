FROM python:3.12-slim

# Set environment variables (non-build-arg ones first)
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV DJANGO_SETTINGS_MODULE=remotelab.settings

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

# Build arguments for version information when building and pushing the initial image. We do this because getting an image built to run during cluster initialization is non-trivial, and this is a simple way to have something running on startup.
ARG APP_VERSION=initial
ARG BUILD_COMMIT=initial
ARG BUILD_DATE=initial

# Set build-arg-dependent environment variables when pushing to Gitea. This overrides the settings above so we can verify the GitOps pipeline.
ENV APP_VERSION=${APP_VERSION}
ENV BUILD_COMMIT=${BUILD_COMMIT}
ENV BUILD_DATE=${BUILD_DATE}

# Inject build information into version.py
RUN sed -i "s/BUILD_COMMIT = \"initial\"/BUILD_COMMIT = \"${BUILD_COMMIT}\"/" version.py && \
    sed -i "s/BUILD_DATE = \"initial\"/BUILD_DATE = \"${BUILD_DATE}\"/" version.py

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
      org.opencontainers.image.title="Remotelab Django Application" \
      org.opencontainers.image.description="Simple Django REST API for K3s remotelab demo"

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:8000/api/health/ || exit 1

# Run the application
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "3", "--timeout", "120", "remotelab.wsgi:application"]
