"""
Version information for the Django application.
These values will be injected during the Docker build process.
"""

# Base version (major.minor)
BASE_VERSION = "1.0"

# These will be injected during Docker build
BUILD_COMMIT = "initial"
BUILD_DATE = "initial"

# Construct full version string
def get_version():
    """Returns the full version string."""
    return f"{BASE_VERSION}.{BUILD_COMMIT[:7] if BUILD_COMMIT != 'initial' else 'initial'}"

def get_commit_sha():
    """Returns the commit SHA (first 7 characters)."""
    return BUILD_COMMIT[:7] if BUILD_COMMIT != "initial" else "initial"

def get_build_date():
    """Returns the build date."""
    return BUILD_DATE
