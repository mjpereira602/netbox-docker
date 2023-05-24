UPDATE
  users_token
SET
  key = '0123456789abcdef0123456789abcdef01234567'
WHERE
  user_id = (SELECT id FROM auth_user WHERE username = 'admin')
