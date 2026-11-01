# Development image for the PlanMeter GTK app: Debian trixie (GTK 4.18,
# libadwaita 1.7), the Rust toolchain, and what headless screenshots need.
FROM rust:1-trixie

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libgtk-4-dev libadwaita-1-dev \
      xvfb xauth dbus dbus-x11 \
      adwaita-icon-theme librsvg2-common \
      libgl1-mesa-dri libegl1 \
      fonts-cantarell fonts-dejavu-core fonts-noto-color-emoji \
      desktop-file-utils appstream \
 && (apt-get install -y --no-install-recommends fonts-adwaita || true) \
 && rm -rf /var/lib/apt/lists/*

RUN rustup component add rustfmt clippy

# GNOME's interface font, as a desktop session would configure it.
RUN mkdir -p /etc/gtk-4.0 \
 && if fc-list | grep -qi "Adwaita Sans"; then font="Adwaita Sans 11"; else font="Cantarell 11"; fi \
 && printf '[Settings]\ngtk-font-name=%s\n' "$font" > /etc/gtk-4.0/settings.ini

WORKDIR /src/linux
