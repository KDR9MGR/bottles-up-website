-- Separate banner image (wide hero shot for the event detail page) from the
-- cover image, which is used for the homepage event card thumbnail.
alter table public.site_events add column banner_image_url text;
