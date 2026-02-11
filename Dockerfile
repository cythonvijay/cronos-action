FROM bash:5.2

RUN apk add --no-cache curl jq git

WORKDIR /action
COPY entrypoint.sh /action/entrypoint.sh
RUN chmod +x /action/entrypoint.sh

ENTRYPOINT ["/action/entrypoint.sh"]
