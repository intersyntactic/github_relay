# Multi-arch: the OCI host this is deployed to is aarch64; see
# .github/workflows/publish.yml, which builds linux/amd64,linux/arm64 and
# refuses to publish a manifest missing arm64.
FROM dart:stable AS build
WORKDIR /app
COPY pubspec.yaml ./
RUN dart pub get
COPY . .
RUN dart pub get --offline
RUN dart compile exe bin/github_relay.dart -o bin/github_relay

# A static binary needs nothing from the SDK image at runtime.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/bin/github_relay /app/bin/github_relay
EXPOSE 8085
ENV HOST=0.0.0.0
ENV PORT=8085
ENTRYPOINT ["/app/bin/github_relay"]
