FROM dart:stable AS build
WORKDIR /app

COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

COPY . .
RUN mkdir -p /app/build \
	&& dart compile exe bin/server.dart -o /app/build/server

FROM debian:bookworm-slim AS runtime
WORKDIR /app

RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates curl \
	&& rm -rf /var/lib/apt/lists/*

RUN groupadd --system skycast \
	&& useradd --system --gid skycast --home /app --shell /usr/sbin/nologin skycast

COPY --from=build /app/build/server /app/server
COPY openapi.yaml /app/openapi.yaml

RUN chown -R skycast:skycast /app \
	&& chmod +x /app/server

USER skycast
EXPOSE 8081

ENTRYPOINT ["/app/server"]
