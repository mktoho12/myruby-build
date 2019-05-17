FROM ubuntu:18.04

RUN apt-get update && apt-get install -y \
  git \
  ruby \
  autoconf \
  bison \
  gcc \
  make \
  zlib1g-dev \
  libffi-dev \
  libreadline-dev \
  libgdbm-dev \
  libssl-dev \
  && rm -rf /var/lib/apt/lists/*

RUN mkdir /workdir
WORKDIR /workdir

CMD ["echo", "hello"]
