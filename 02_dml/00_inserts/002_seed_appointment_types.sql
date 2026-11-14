-- DB-12 (HU-APT-006): initial catalog; real configuration, so it runs in every environment.
INSERT INTO appointments.appointment_types (code, label, color, active, sort_order) VALUES
    ('CONSULTA', 'Consulta general', '#2563EB', true, 10),
    ('LIMPIEZA', 'Limpieza', '#0D9488', true, 20),
    ('CONTROL', 'Control', '#7C3AED', true, 30),
    ('ORTODONCIA', 'Ortodoncia', '#DB2777', true, 40),
    ('ENDODONCIA', 'Endodoncia', '#EA580C', true, 50),
    ('EXTRACCION', 'Extracción', '#DC2626', true, 60),
    ('URGENCIA', 'Urgencia', '#B91C1C', true, 70);
