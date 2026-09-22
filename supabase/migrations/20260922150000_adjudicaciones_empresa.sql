-- ============================================================
-- adjudicaciones_empresa: una fila por licitación y empresa ganadora
-- ============================================================
--
-- PENDIENTE DE APLICAR (escrita el 22/09/2026).
--
-- Hasta ahora todas las cifras por empresa salían de
-- `licitaciones.adjudicatario_cif`, que guarda UN ganador por
-- expediente: el que más se llevó. Quien ganaba un lote sin ser el
-- principal no existía para ese contrato. Medido el 22/09/2026:
-- 190.488 lotes de 47.933 licitaciones, de 42.013 empresas, con
-- 52.614 M€ fuera de acuerdos marco que no se apuntaba nadie (frente a
-- 282.416 M€ atribuidos). Soltec ganó lotes en 4 licitaciones que no
-- le contaban. Una empresa que SOLO gana lotes secundarios ni siquiera
-- aparecía en el catálogo, así que no podía darse de alta.
--
-- Esta tabla reparte cada licitación entre todos sus ganadores:
--
--   - `lotes`: cuántos lotes ganó esa empresa en ese expediente. Una
--     licitación cuenta como UN contrato aunque gane tres lotes; los
--     lotes van aparte (decidido el 22/09/2026).
--   - `importe`: su parte. El total si ganó sola; la suma de sus lotes
--     si hubo varios ganadores y los lotes cuadran con el total; nada
--     si no cuadran (acuerdos marco, lotes que repiten el importe del
--     expediente entero). Mejor un hueco que un número falso.
--   - `principal`: si es la que figura en `adjudicatario_cif`.
--
-- La mantiene un disparador sobre `licitaciones`, así que el lector, el
-- histórico y `refrescar_licitaciones` no cambian.
--
-- Orden de aplicación (cada tramo por separado):
--   1. Tabla, reparto y disparador.
--   2. Relleno, por tandas de páginas (al final del fichero).
--   3. Funciones que leen de aquí.
--   4. Agregados: catálogo de empresas, empresas_por_cif.
-- ============================================================


-- ============================================================
-- TRAMO 1: tabla, reparto y disparador
-- ============================================================

create table if not exists public.adjudicaciones_empresa (
    id_licitacion text not null
        references public.licitaciones (id_licitacion) on delete cascade,
    cif        text    not null,
    nombre     text,
    importe    numeric,
    lotes      integer not null default 1,
    principal  boolean not null default false,
    primary key (id_licitacion, cif)
);

create index if not exists idx_adjudicaciones_empresa_cif
    on public.adjudicaciones_empresa (cif);

-- Solo se lee a través de funciones con SECURITY DEFINER.
alter table public.adjudicaciones_empresa enable row level security;
revoke all on public.adjudicaciones_empresa from anon, authenticated;


-- El reparto de una licitación entre sus ganadores.
--
-- Sin `set search_path`: no toca tablas, y así se expande en línea.
create or replace function public.reparto_adjudicacion(
    adjudicaciones jsonb, nombre_principal text, cif_principal text,
    total numeric)
returns table(cif text, nombre text, importe numeric, lotes integer,
              principal boolean)
language sql
immutable
as $function$
    with lote as (
        select a.value->>'cif' as cif,
               nullif(a.value->>'adjudicatario', '') as nombre,
               case when jsonb_typeof(a.value->'importe') = 'number'
                    then (a.value->>'importe')::numeric end as importe
        from jsonb_array_elements(
                 case when jsonb_typeof(adjudicaciones) = 'array'
                      then adjudicaciones else '[]'::jsonb end) a
        where coalesce(a.value->>'cif', '') <> ''
    ),
    por_cif as (
        select lote.cif,
               (array_agg(lote.nombre) filter (where lote.nombre is not null))[1] as nombre,
               count(*)::int as n,
               sum(lote.importe) as suma
        from lote group by lote.cif
        -- El principal siempre tiene su fila, aunque su lote no traiga
        -- CIF: es lo que ya se contaba antes de esta tabla.
        union all
        select cif_principal, nombre_principal, 1, null
        where coalesce(cif_principal, '') <> ''
          and not exists (select 1 from lote where lote.cif = cif_principal)
    ),
    cuadre as (
        select (select count(*) from por_cif) as ganadores,
               -- Los lotes solo se pueden repartir si suman el total. En
               -- un acuerdo marco cada lote publica el marco entero, y la
               -- suma se dispara.
               (select coalesce(sum(lote.importe), 0) from lote)
                   <= total * 1.01 as cuadra
    )
    select p.cif,
           case when p.cif = cif_principal
                then coalesce(nombre_principal, p.nombre) else p.nombre end,
           case when total is null then null
                when c.ganadores = 1 then total
                when c.cuadra then least(nullif(p.suma, 0), total)
                else null end,
           p.n,
           p.cif is not distinct from cif_principal
    from por_cif p cross join cuadre c
$function$;

revoke execute on function public.reparto_adjudicacion(jsonb, text, text, numeric)
    from public, anon, authenticated;


create or replace function public.sincronizar_adjudicaciones_empresa()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
    -- El scraper reescribe filas enteras en cada pasada: solo se rehace
    -- si cambió algo que afecta al reparto.
    if tg_op = 'UPDATE'
       and new.adjudicaciones is not distinct from old.adjudicaciones
       and new.adjudicatario is not distinct from old.adjudicatario
       and new.adjudicatario_cif is not distinct from old.adjudicatario_cif
       and new.importe_adjudicacion is not distinct from old.importe_adjudicacion
    then
        return null;
    end if;

    delete from public.adjudicaciones_empresa
    where id_licitacion = new.id_licitacion;

    insert into public.adjudicaciones_empresa
        (id_licitacion, cif, nombre, importe, lotes, principal)
    select new.id_licitacion, r.cif, r.nombre, r.importe, r.lotes, r.principal
    from public.reparto_adjudicacion(new.adjudicaciones, new.adjudicatario,
                                     new.adjudicatario_cif,
                                     new.importe_adjudicacion) r;
    return null;
end;
$function$;

revoke execute on function public.sincronizar_adjudicaciones_empresa()
    from public, anon, authenticated;

drop trigger if exists trg_adjudicaciones_empresa on public.licitaciones;
create trigger trg_adjudicaciones_empresa
    after insert or update of adjudicaciones, adjudicatario,
                              adjudicatario_cif, importe_adjudicacion
    on public.licitaciones
    for each row execute function public.sincronizar_adjudicaciones_empresa();


-- ============================================================
-- TRAMO 2: relleno (se ejecutó por tandas de páginas, así)
-- ============================================================
--
--   insert into public.adjudicaciones_empresa
--       (id_licitacion, cif, nombre, importe, lotes, principal)
--   select l.id_licitacion, r.cif, r.nombre, r.importe, r.lotes, r.principal
--   from public.licitaciones l
--   cross join lateral public.reparto_adjudicacion(
--       l.adjudicaciones, l.adjudicatario, l.adjudicatario_cif,
--       l.importe_adjudicacion) r
--   where l.ctid >= '(DESDE,0)'::tid and l.ctid < '(HASTA,0)'::tid
--   on conflict do nothing;
