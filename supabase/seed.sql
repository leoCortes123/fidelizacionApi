-- Datos iniciales de configuración y catálogo. No crea usuarios.
insert into public.program_settings (
  id, cop_per_point_unit, min_purchase_amount, max_points_per_purchase,
  qr_expiry_hours, points_expiry_days, history_page_size
) values (true, 1000, 0, 500, 24, null, 10)
on conflict (id) do nothing;

insert into public.rewards (id, name, description, points_cost, is_active)
values
  ('11111111-1111-4111-8111-111111111111', 'Taco individual', 'Un taco de guisado o suadero con doble tortilla.', 40, true),
  ('22222222-2222-4222-8222-222222222222', 'Combo Enganche', 'Dos tacos de guisado.', 80, true),
  ('33333333-3333-4333-8333-333333333333', 'Gringa', 'Tortilla de harina, queso fundido y carne.', 90, true),
  ('44444444-4444-4444-8444-444444444444', 'Agua fresca', 'Vaso de horchata o jamaica.', 30, true),
  ('55555555-5555-4555-8555-555555555555', 'Consomé gachupa', 'Vaso de consomé caliente de suadero.', 20, true)
on conflict (id) do nothing;
