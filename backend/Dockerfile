FROM dart:stable AS build
WORKDIR /app

COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

COPY . .

EXPOSE 8081

CMD ["dart", "run", "bin/server.dart"]
