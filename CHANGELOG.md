# CHANGELOG

# Upcoming...

# v0.0.1.6

- Fix a bug where batched metrics would send an empty list to the server. This
  causes the service to respond with an error.

# v0.0.1.5

- Batch metric requests to Cloudwatch, resulting in cheaper operations.

