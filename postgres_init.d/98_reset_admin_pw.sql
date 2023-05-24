UPDATE
  auth_user
SET
  password='pbkdf2_sha256$260000$5cQvjWzQCPFPYjAE6vJhc7$NL1kM6QOGre1SqBedaSVvgb/SM2LcaRfP6O+hN7SlK8=',
  email='admin@foo.bar'
WHERE username = 'admin';
