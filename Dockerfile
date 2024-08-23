FROM debian:stable-slim
RUN apt-get update
RUN apt-get -qq -y install git wget
RUN apt-get clean && rm -rf /var/lib/apt/lists/\* /tmp/\* /var/tmp/*

WORKDIR /app

RUN git clone https://github.com/jojo2357/kiwix-zim-updater.git ./data

RUN chmod +x /app/data/kiwix-zim-updater.sh
ENTRYPOINT ["/bin/bash", "/app/data/kiwix-zim-updater.sh", "-d", "/data"]