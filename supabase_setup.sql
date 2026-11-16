-- Supermarket Manager: additive database setup
-- Run once in Supabase SQL Editor. Take a database backup first.
-- Uses existing products, profiles and moves tables from the earlier setup.

create extension if not exists pgcrypto;

alter table public.products add column if not exists units_per_carton integer not null default 1;
alter table public.products add column if not exists carton_cost numeric(12,2) not null default 0;
alter table public.products add column if not exists carton_price numeric(12,2) not null default 0;
alter table public.products add column if not exists notes text;

create table if not exists public.suppliers (
 id uuid primary key default gen_random_uuid(), name text not null, phone text, address text,
 created_at timestamptz not null default now(), created_by uuid references auth.users(id)
);
create table if not exists public.customers (
 id uuid primary key default gen_random_uuid(), name text not null, phone text, address text,
 created_at timestamptz not null default now(), created_by uuid references auth.users(id)
);
create table if not exists public.purchases (
 id uuid primary key default gen_random_uuid(), invoice_no text unique,
 supplier_id uuid references public.suppliers(id), supplier_name text, total numeric(12,2) not null default 0,
 status text not null default 'posted' check(status in ('draft','posted','cancelled')),
 notes text, payment_method text not null default 'cash', created_at timestamptz not null default now(),
 created_by uuid references auth.users(id)
);
create table if not exists public.purchase_items (
 id uuid primary key default gen_random_uuid(), purchase_id uuid not null references public.purchases(id) on delete cascade,
 product_id text not null references public.products(id), unit text not null default 'piece' check(unit in ('piece','carton')),
 qty numeric(12,3) not null, units_per_carton integer not null default 1, qty_pieces numeric(12,3) not null,
 unit_price numeric(12,2) not null default 0, line_total numeric(12,2) not null default 0,
 expiry_date date, created_at timestamptz not null default now()
);
create table if not exists public.sales (
 id uuid primary key default gen_random_uuid(), invoice_no text unique,
 customer_id uuid references public.customers(id), customer_name text, total numeric(12,2) not null default 0,
 status text not null default 'posted' check(status in ('draft','posted','cancelled')),
 notes text, payment_method text not null default 'cash', created_at timestamptz not null default now(),
 created_by uuid references auth.users(id)
);
create table if not exists public.sale_items (
 id uuid primary key default gen_random_uuid(), sale_id uuid not null references public.sales(id) on delete cascade,
 product_id text not null references public.products(id), unit text not null default 'piece' check(unit in ('piece','carton')),
 qty numeric(12,3) not null, units_per_carton integer not null default 1, qty_pieces numeric(12,3) not null,
 unit_price numeric(12,2) not null default 0, line_total numeric(12,2) not null default 0,
 created_at timestamptz not null default now()
);
create table if not exists public.product_batches (
 id uuid primary key default gen_random_uuid(), product_id text not null references public.products(id),
 purchase_item_id uuid references public.purchase_items(id), batch_no text,
 expiry_date date, qty_initial numeric(12,3) not null default 0, qty_remaining numeric(12,3) not null default 0,
 unit_cost numeric(12,2) not null default 0, created_at timestamptz not null default now()
);
create table if not exists public.sale_item_batches (
 id uuid primary key default gen_random_uuid(), sale_item_id uuid not null references public.sale_items(id) on delete cascade,
 batch_id uuid not null references public.product_batches(id), qty numeric(12,3) not null default 0
);
create table if not exists public.cash_transactions (
 id uuid primary key default gen_random_uuid(), transaction_type text not null check(transaction_type in ('income','expense')),
 payment_method text not null default 'cash' check(payment_method in ('cash','card','instapay','other')),
 amount numeric(12,2) not null check(amount>0), description text, reference_type text, reference_id uuid,
 created_by uuid references auth.users(id), created_at timestamptz not null default now()
);
create table if not exists public.audit_logs (
 id bigint generated always as identity primary key, user_id uuid references auth.users(id),
 action text not null, table_name text, record_id text, details jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);

-- Ensure columns exist if the tables were created by the previous project migration.
alter table public.product_batches add column if not exists batch_no text;
alter table public.product_batches add column if not exists expiry_date date;
alter table public.product_batches add column if not exists qty_initial numeric(12,3) not null default 0;
alter table public.product_batches add column if not exists qty_remaining numeric(12,3) not null default 0;
alter table public.product_batches add column if not exists unit_cost numeric(12,2) not null default 0;

create index if not exists idx_batches_product_expiry on public.product_batches(product_id, expiry_date);
create index if not exists idx_sales_created on public.sales(created_at desc);
create index if not exists idx_purchases_created on public.purchases(created_at desc);
create index if not exists idx_cash_created on public.cash_transactions(created_at desc);

-- All authenticated staff accounts share the same application permissions.
-- Do not grant anon access. Existing products policies are replaced deliberately.
alter table public.products enable row level security;
alter table public.suppliers enable row level security;
alter table public.customers enable row level security;
alter table public.purchases enable row level security;
alter table public.purchase_items enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.product_batches enable row level security;
alter table public.sale_item_batches enable row level security;
alter table public.cash_transactions enable row level security;
alter table public.audit_logs enable row level security;

drop policy if exists "products_select_authenticated" on public.products;
drop policy if exists "products_insert_authenticated" on public.products;
drop policy if exists "products_update_admin" on public.products;
drop policy if exists "products_delete_admin" on public.products;
drop policy if exists "products_all_authenticated" on public.products;
create policy "products_all_authenticated" on public.products for all to authenticated using (true) with check (true);

do $$
declare t text;
begin
 foreach t in array array['suppliers','customers','purchases','purchase_items','sales','sale_items','product_batches','sale_item_batches','cash_transactions'] loop
   execute format('drop policy if exists %I on public.%I', t||'_all_authenticated', t);
   execute format('create policy %I on public.%I for all to authenticated using (true) with check (true)', t||'_all_authenticated', t);
 end loop;
end $$;
drop policy if exists "audit_logs_select_authenticated" on public.audit_logs;
create policy "audit_logs_select_authenticated" on public.audit_logs for select to authenticated using (true);

-- Purchase invoice: atomic stock increase, batch creation, cash movement and audit.
create or replace function public.create_purchase_invoice(
 p_party_id uuid, p_payment_method text, p_notes text, p_items jsonb
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_uid uuid:=auth.uid(); v_invoice uuid; v_item jsonb; v_product public.products%rowtype;
 v_qty numeric; v_pieces numeric; v_unit text; v_price numeric; v_total numeric:=0;
 v_item_id uuid; v_batch_id uuid; v_party_name text;
begin
 if v_uid is null then raise exception 'يجب تسجيل الدخول'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'الفاتورة لا تحتوي أصناف'; end if;
 if p_payment_method not in ('cash','card','instapay','other') then raise exception 'طريقة دفع غير صحيحة'; end if;
 if p_party_id is not null then select name into v_party_name from suppliers where id=p_party_id; end if;
 insert into purchases(supplier_id,supplier_name,status,notes,payment_method,created_by)
 values(p_party_id,v_party_name,'posted',p_notes,p_payment_method,v_uid) returning id into v_invoice;
 update purchases set invoice_no='PUR-'||to_char(now(),'YYMMDD')||'-'||right(v_invoice::text,6) where id=v_invoice;
 for v_item in select * from jsonb_array_elements(p_items) loop
   select * into v_product from products where id=(v_item->>'product_id') for update;
   if not found then raise exception 'يوجد صنف غير موجود'; end if;
   v_qty:=(v_item->>'qty')::numeric; v_unit:=coalesce(v_item->>'unit','piece');
   if v_qty<=0 or v_unit not in ('piece','carton') then raise exception 'كمية أو وحدة غير صحيحة'; end if;
   v_pieces:=case when v_unit='carton' then v_qty*v_product.units_per_carton else v_qty end;
   v_price:=coalesce((v_item->>'unit_price')::numeric,case when v_unit='carton' then v_product.carton_cost else v_product.cost end);
   insert into purchase_items(purchase_id,product_id,unit,qty,units_per_carton,qty_pieces,unit_price,line_total,expiry_date)
   values(v_invoice,v_product.id,v_unit,v_qty,v_product.units_per_carton,v_pieces,v_price,v_qty*v_price,nullif(v_item->>'expiry_date','')::date)
   returning id into v_item_id;
   update products set qty=coalesce(qty,0)+v_pieces where id=v_product.id;
   if nullif(v_item->>'expiry_date','') is not null then
     insert into product_batches(product_id,purchase_item_id,batch_no,expiry_date,qty_initial,qty_remaining,unit_cost)
     values(v_product.id,v_item_id,'B-'||right(v_item_id::text,8),(v_item->>'expiry_date')::date,v_pieces,v_pieces,
       case when v_unit='carton' then v_price/nullif(v_product.units_per_carton,0) else v_price end) returning id into v_batch_id;
   end if;
   v_total:=v_total+v_qty*v_price;
 end loop;
 update purchases set total=v_total where id=v_invoice;
 insert into cash_transactions(transaction_type,payment_method,amount,description,reference_type,reference_id,created_by)
 values('expense',p_payment_method,v_total,'سداد فاتورة مشتريات','purchase',v_invoice,v_uid);
 insert into audit_logs(user_id,action,table_name,record_id,details) values(v_uid,'create_purchase','purchases',v_invoice::text,jsonb_build_object('total',v_total));
 return v_invoice;
end $$;

-- Sale invoice: stock is deducted FIFO from expiring batches first, then unbatched stock.
create or replace function public.create_sale_invoice(
 p_party_id uuid, p_payment_method text, p_notes text, p_items jsonb
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_uid uuid:=auth.uid(); v_invoice uuid; v_item jsonb; v_product public.products%rowtype;
 v_qty numeric; v_pieces numeric; v_unit text; v_price numeric; v_total numeric:=0;
 v_item_id uuid; v_need numeric; v_take numeric; v_batch record; v_party_name text;
begin
 if v_uid is null then raise exception 'يجب تسجيل الدخول'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'الفاتورة لا تحتوي أصناف'; end if;
 if p_payment_method not in ('cash','card','instapay','other') then raise exception 'طريقة دفع غير صحيحة'; end if;
 if p_party_id is not null then select name into v_party_name from customers where id=p_party_id; end if;
 insert into sales(customer_id,customer_name,status,notes,payment_method,created_by)
 values(p_party_id,coalesce(v_party_name,'عميل نقدي'),'posted',p_notes,p_payment_method,v_uid) returning id into v_invoice;
 update sales set invoice_no='SAL-'||to_char(now(),'YYMMDD')||'-'||right(v_invoice::text,6) where id=v_invoice;
 for v_item in select * from jsonb_array_elements(p_items) loop
   select * into v_product from products where id=(v_item->>'product_id') for update;
   if not found then raise exception 'يوجد صنف غير موجود'; end if;
   v_qty:=(v_item->>'qty')::numeric; v_unit:=coalesce(v_item->>'unit','piece');
   if v_qty<=0 or v_unit not in ('piece','carton') then raise exception 'كمية أو وحدة غير صحيحة'; end if;
   v_pieces:=case when v_unit='carton' then v_qty*v_product.units_per_carton else v_qty end;
   if coalesce(v_product.qty,0)<v_pieces then raise exception 'المخزون غير كافٍ للصنف: %',v_product.name; end if;
   v_price:=coalesce((v_item->>'unit_price')::numeric,case when v_unit='carton' then v_product.carton_price else v_product.price end);
   insert into sale_items(sale_id,product_id,unit,qty,units_per_carton,qty_pieces,unit_price,line_total)
   values(v_invoice,v_product.id,v_unit,v_qty,v_product.units_per_carton,v_pieces,v_price,v_qty*v_price) returning id into v_item_id;
   v_need:=v_pieces;
   for v_batch in select * from product_batches where product_id=v_product.id and qty_remaining>0 order by expiry_date nulls last,created_at for update loop
     exit when v_need<=0;
     v_take:=least(v_need,v_batch.qty_remaining);
     update product_batches set qty_remaining=qty_remaining-v_take where id=v_batch.id;
     insert into sale_item_batches(sale_item_id,batch_id,qty) values(v_item_id,v_batch.id,v_take);
     v_need:=v_need-v_take;
   end loop;
   update products set qty=coalesce(qty,0)-v_pieces where id=v_product.id;
   v_total:=v_total+v_qty*v_price;
 end loop;
 update sales set total=v_total where id=v_invoice;
 insert into cash_transactions(transaction_type,payment_method,amount,description,reference_type,reference_id,created_by)
 values('income',p_payment_method,v_total,'تحصيل فاتورة مبيعات','sale',v_invoice,v_uid);
 insert into audit_logs(user_id,action,table_name,record_id,details) values(v_uid,'create_sale','sales',v_invoice::text,jsonb_build_object('total',v_total));
 return v_invoice;
end $$;

revoke all on function public.create_purchase_invoice(uuid,text,text,jsonb) from public;
revoke all on function public.create_sale_invoice(uuid,text,text,jsonb) from public;
grant execute on function public.create_purchase_invoice(uuid,text,text,jsonb) to authenticated;
grant execute on function public.create_sale_invoice(uuid,text,text,jsonb) to authenticated;

-- Enable realtime for operational tables (ignore if already published).
do $$
declare t text;
begin
 foreach t in array array['products','moves','product_batches','sales','purchases','cash_transactions'] loop
   begin execute format('alter publication supabase_realtime add table public.%I',t);
   exception when duplicate_object then null; when undefined_object then null; end;
 end loop;
end $$;
