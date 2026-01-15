# =============================================================================
# iRedMail Docker Image
# Production-ready mail server with all components
# =============================================================================
FROM ubuntu:22.04

LABEL maintainer="iRedMail Docker Custom"
LABEL version="1.2.0"
LABEL description="Production-ready iRedMail Docker image with s6-overlay"

# =============================================================================
# Build Arguments (pinned versions - update periodically)
# =============================================================================
ARG DEBIAN_FRONTEND=noninteractive
ARG S6_OVERLAY_VERSION=3.2.0.3
ARG IREDMAIL_VERSION=1.7.1
ARG ROUNDCUBE_VERSION=1.6.12
ARG IREDAPD_VERSION=5.9.1
ARG IREDADMIN_VERSION=2.7

# =============================================================================
# Environment Variables
# =============================================================================
ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    S6_KEEP_ENV=1 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=300000 \
    S6_VERBOSITY=1

# =============================================================================
# Install s6-overlay
# =============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends xz-utils && rm -rf /var/lib/apt/lists/*
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp/
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-x86_64.tar.xz /tmp/
RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-x86_64.tar.xz && \
    rm -f /tmp/s6-overlay-*.tar.xz

# =============================================================================
# Install Base System Packages
# =============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Locales
    locales \
    # Core utilities
    curl wget gnupg ca-certificates apt-transport-https \
    software-properties-common lsb-release \
    # Build tools (for some packages)
    build-essential python3-dev libldap2-dev libsasl2-dev \
    default-libmysqlclient-dev pkg-config \
    # Python
    python3 python3-pip python3-setuptools python3-wheel \
    # Network tools
    netcat-openbsd dnsutils telnet net-tools \
    # Editors and tools
    vim less procps \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# Add SOGo Repository
# =============================================================================
RUN curl -fsSL https://keys.openpgp.org/vks/v1/by-fingerprint/74FFC6D72B925A34B5D356BDF8A27B36A6E2EAE9 | \
    gpg --dearmor -o /usr/share/keyrings/sogo-nightly.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/sogo-nightly.gpg] https://packages.sogo.nu/nightly/5/ubuntu jammy jammy" \
    > /etc/apt/sources.list.d/sogo.list

# =============================================================================
# Install Mail Server Components
# =============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    # -------------------------------------------------------------------------
    # MTA: Postfix
    # -------------------------------------------------------------------------
    postfix postfix-mysql postfix-pcre libsasl2-modules \
    # -------------------------------------------------------------------------
    # MDA: Dovecot
    # -------------------------------------------------------------------------
    dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd \
    dovecot-mysql dovecot-sieve dovecot-managesieved \
    # -------------------------------------------------------------------------
    # Anti-spam & Anti-virus
    # -------------------------------------------------------------------------
    amavisd-new spamassassin spamc \
    clamav clamav-daemon clamav-freshclam \
    libmail-dkim-perl libcrypt-openssl-rsa-perl \
    arj bzip2 cabextract cpio lzop nomarch p7zip-full rpm unrar-free unzip zip \
    # -------------------------------------------------------------------------
    # SASL Authentication (Fix for Issue #3)
    # -------------------------------------------------------------------------
    libsasl2-2 libsasl2-modules libsasl2-modules-db sasl2-bin \
    # -------------------------------------------------------------------------
    # Web Server
    # -------------------------------------------------------------------------
    nginx \
    # -------------------------------------------------------------------------
    # PHP
    # -------------------------------------------------------------------------
    php-fpm php-mysql php-mbstring php-xml php-intl php-curl \
    php-gd php-json php-zip php-ldap php-pear php-imagick \
    php-pspell php-redis \
    # -------------------------------------------------------------------------
    # SOGo Groupware
    # -------------------------------------------------------------------------
    sogo sogo-activesync \
    # -------------------------------------------------------------------------
    # Database Client
    # -------------------------------------------------------------------------
    mariadb-client \
    # -------------------------------------------------------------------------
    # Logging
    # -------------------------------------------------------------------------
    rsyslog logrotate \
    # -------------------------------------------------------------------------
    # OpenDKIM
    # -------------------------------------------------------------------------
    opendkim opendkim-tools \
    # -------------------------------------------------------------------------
    # Utilities
    # -------------------------------------------------------------------------
    cron supervisor \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# Install mlmmj (Mailing List Manager)
# =============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    mlmmj \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# Download and Install Roundcube
# =============================================================================
RUN mkdir -p /var/www/roundcube && \
    curl -fsSL https://github.com/roundcube/roundcubemail/releases/download/${ROUNDCUBE_VERSION}/roundcubemail-${ROUNDCUBE_VERSION}-complete.tar.gz | \
    tar -xz -C /var/www/roundcube --strip-components=1 && \
    chown -R www-data:www-data /var/www/roundcube && \
    chmod -R 755 /var/www/roundcube

# =============================================================================
# Download and Install iRedAPD
# =============================================================================
RUN mkdir -p /opt/iredapd && \
    curl -fsSL https://github.com/iredmail/iRedAPD/archive/refs/tags/${IREDAPD_VERSION}.tar.gz | \
    tar -xz -C /opt/iredapd --strip-components=1 && \
    cp /opt/iredapd/rc_scripts/iredapd.service /etc/systemd/system/ 2>/dev/null || true

# =============================================================================
# Download and Install iRedAdmin (Free Version)
# =============================================================================
RUN mkdir -p /var/www/iredadmin && \
    curl -fsSL https://github.com/iredmail/iRedAdmin/archive/refs/tags/${IREDADMIN_VERSION}.tar.gz | \
    tar -xz -C /var/www/iredadmin --strip-components=1 && \
    chown -R www-data:www-data /var/www/iredadmin && \
    chmod -R 755 /var/www/iredadmin

# =============================================================================
# Install Python Packages (pinned versions for stability)
# =============================================================================
# Combined requirements from iRedAPD and iRedAdmin
# All versions pinned for reproducible builds - update periodically
RUN pip3 install --no-cache-dir \
    'web.py==0.62' \
    'Jinja2==3.1.5' \
    'python-ldap==3.4.5' \
    'PyMySQL==1.1.2' \
    'mysqlclient==2.2.7' \
    'psycopg2-binary==2.9.11' \
    'requests==2.32.4' \
    'dnspython==2.8.0' \
    'netifaces==0.11.0' \
    'bcrypt==4.2.1' \
    'simplejson==3.20.2' \
    'SQLAlchemy==2.0.36' \
    'uwsgi==2.0.28' \
    'more-itertools==10.5.0'

# =============================================================================
# Create Required Users and Groups
# =============================================================================
RUN groupadd -g 2000 vmail && \
    useradd -u 2000 -g vmail -d /var/vmail -s /sbin/nologin -c "Virtual Mail User" vmail && \
    mkdir -p /var/vmail/vmail1 && \
    chown -R vmail:vmail /var/vmail && \
    chmod -R 700 /var/vmail

# =============================================================================
# Create Required Directories
# =============================================================================
RUN mkdir -p \
    /var/lib/dkim \
    /var/lib/clamav \
    /var/lib/spamassassin \
    /var/lib/sogo \
    /var/log/iredmail \
    /var/log/nginx \
    /var/log/php \
    /var/log/sogo \
    /opt/iredmail/custom \
    /opt/iredmail/state \
    /opt/iredmail/sql \
    /var/www/certbot \
    /run/php \
    /run/sogo \
    /run/dovecot \
    /run/amavis \
    /run/clamav \
    /run/opendkim \
    && chown -R clamav:clamav /var/lib/clamav /run/clamav \
    && chown -R sogo:sogo /var/lib/sogo /run/sogo /var/log/sogo \
    && chown -R www-data:www-data /run/php

# =============================================================================
# Copy s6-overlay Service Definitions
# =============================================================================
COPY rootfs/ /

# =============================================================================
# Copy SQL Initialization Scripts
# =============================================================================
COPY sql/ /opt/iredmail/sql/

# =============================================================================
# Set Permissions for s6 Scripts
# =============================================================================
RUN find /etc/s6-overlay -type f -name "run" -exec chmod 755 {} \; && \
    find /etc/s6-overlay -type f -name "finish" -exec chmod 755 {} \; && \
    find /etc/s6-overlay -type f -name "up" -exec chmod 755 {} \; && \
    chmod 755 /etc/s6-overlay/scripts/*.sh 2>/dev/null || true

# =============================================================================
# Expose Ports
# =============================================================================
# SMTP
EXPOSE 25 465 587
# POP3
EXPOSE 110 995
# IMAP
EXPOSE 143 993
# HTTP/HTTPS
EXPOSE 80 443
# ManageSieve
EXPOSE 4190

# =============================================================================
# Health Check
# =============================================================================
HEALTHCHECK --interval=60s --timeout=30s --start-period=300s --retries=3 \
    CMD /usr/local/bin/health-check.sh || exit 1

# =============================================================================
# Entrypoint
# =============================================================================
ENTRYPOINT ["/init"]
