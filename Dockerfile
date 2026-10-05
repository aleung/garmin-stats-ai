# Shared image for both apps. Both subprojects target Python >=3.11 and have
# overlapping deps (pandas etc.), so one image serves both the fetcher and web.
FROM python:3.11-slim

# - build-essential: some wheels (scipy/pandas) may need to compile on arm/slim
# - tini: proper PID 1 so SIGTERM reaches Python and ctrl-c / docker stop is clean
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential tini \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy only the two subproject trees needed to install the packages.
# (The build context is the repo root; see docker-compose.yml.)
COPY garmin-grafana/ /app/garmin-grafana/
COPY garmin-insights/ /app/garmin-insights/

# Install both packages. pip resolves the union of their dependency pins.
# --no-cache-dir keeps the image small.
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir ./garmin-grafana ./garmin-insights


# The web app serves static assets from <pkg>/web/static, but these non-Python
# files are not declared as package data in pyproject.toml, so pip install drops
# them. Copy them into the installed package so the web server can start.
# (Fix kept in the image to avoid modifying the cloned repo source.)
RUN SITE_PKG=$(python -c "import garmin_insights, os; print(os.path.dirname(garmin_insights.__file__))") \
    && cp -r /app/garmin-insights/src/garmin_insights/web/static "$SITE_PKG/web/static" \
    && ls "$SITE_PKG/web/static"

# Data + token dirs are provided as volumes at runtime; create mountpoints.
RUN mkdir -p /data /tokens

ENTRYPOINT ["/usr/bin/tini", "--"]
# Default command is overridden per-service in docker-compose.yml.
CMD ["garmin-insights", "web"]
