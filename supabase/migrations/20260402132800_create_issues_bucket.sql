-- Create issues bucket
insert into storage.buckets (id, name, public)
values ('issues-attachments', 'issues-attachments', true)
on conflict (id) do nothing;

-- Enable public access for select
create policy "issues_attachments_public_select"
on storage.objects for select
using ( bucket_id = 'issues-attachments' );

-- Enable authenticated access for insert (or public for demo)
create policy "issues_attachments_insert"
on storage.objects for insert
with check ( bucket_id = 'issues-attachments' );
