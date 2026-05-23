FROM redis:7-alpine
COPY docker/redis/docker-entrypoint.sh /usr/local/bin/redis-entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/redis-entrypoint.sh \
    && chmod +x /usr/local/bin/redis-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/redis-entrypoint.sh"]
