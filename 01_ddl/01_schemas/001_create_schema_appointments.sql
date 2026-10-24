-- The executing CURRENT_USER becomes owner and needs CREATE on this database.
-- Production must use the agreed owner-scoped migration role, not the test user.
CREATE SCHEMA appointments AUTHORIZATION CURRENT_USER;
