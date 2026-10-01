-- ============================================================
-- UTEs: quién las forma, sin repartir el dinero
-- ============================================================
--
-- El problema (medido el 01/10/2026):
--
--   Desde 2024, sin menores, 7.730 UTEs ganaron 12.781 adjudicaciones
--   por 42.100 M€ (el 17 % del dinero). La plataforma publica el nombre
--   de la UTE, su NIF y el importe. NO publica los socios ni el reparto:
--   el porcentaje de cada socio está en su contrato privado de UTE, y las
--   UTE no se inscriben en el Registro Mercantil.
--
-- Decidido el 01/10/2026: el modelo de Civio ("¿Quién cobra la obra?",
-- 2016) y Gobierto. La UTE sigue siendo una entidad con sus contratos y
-- su importe (como hasta ahora), y además:
--
--   - en la ficha de una empresa: "UTEs en las que participa";
--   - en la ficha de una UTE: "Empresas que la forman".
--
-- NUNCA se imputan euros a un socio. El importe que se enseña es el de la
-- UTE entera, y así se rotula.
--
-- Quién es socio lo decide `scripts/utes_socios.py`, solo con cruces
-- fiables (precisión ~96 % en una muestra revisada a mano):
--
--   'nif_en_nombre'  el NIF del socio viene escrito en el nombre de la UTE;
--   'nombre_exacto'  un trozo del nombre coincide, sin forma jurídica, con
--                    el de una única sociedad con NIF del catálogo.
--
-- Cobertura medida: algún socio en el 36 % de las UTEs (34 % del dinero),
-- dos o más en el 11 %. El resto son siglas ("UTE INCOPE-CYGSA"), nombres
-- de proyecto ("UTE 3 XEMENEIES") o socios que nunca han ganado solos.
--
-- Aditiva: no toca ninguna tabla ni función existente. Para deshacerla:
--   drop function if exists public.utes_y_socios(text, integer, integer);
--   drop table if exists public.ute_socios;
-- ============================================================

create table if not exists public.ute_socios (
    ute_cif    text not null,    -- como `adjudicaciones_empresa.cif` de la UTE
    socio_cif  text not null,    -- NIF de la sociedad socia
    metodo     text not null check (metodo in ('nif_en_nombre', 'nombre_exacto')),
    trozo      text,             -- parte del nombre que lo identificó
    calculado  timestamptz not null default now(),
    primary key (ute_cif, socio_cif)
);

create index if not exists idx_ute_socios_socio on public.ute_socios (socio_cif);

comment on table public.ute_socios is
    'Socios identificados de cada UTE (scripts/utes_socios.py). Sin reparto '
    'de importes: la plataforma no publica el porcentaje de cada socio.';

-- Se escribe solo con la clave de servicio (el script) y se lee solo a
-- través de `utes_y_socios`.
alter table public.ute_socios enable row level security;
revoke all on public.ute_socios from anon, authenticated;


-- ------------------------------------------------------------
-- utes_y_socios: lo que enseña la ficha de empresa
-- ------------------------------------------------------------
-- Con el NIF de una empresa, las UTEs en las que participa; con el de
-- una UTE, sus socios. Una llamada para los dos casos: la web no sabe
-- de antemano cuál de los dos está mirando.
--
-- Las UTEs se cuentan con los mismos filtros que `ficha_empresa`: sin
-- menores, sin homologaciones y dentro del periodo.
create or replace function public.utes_y_socios(
    cif_buscado text, desde integer default null::integer,
    hasta integer default null::integer)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
    limpio text := upper(regexp_replace(cif_buscado, '[^a-zA-Z0-9]', '', 'g'));
begin
    if public.mi_perfil_id() is null then return '{}'::jsonb; end if;

    return jsonb_build_object(
        'utes', (
            select jsonb_agg(jsonb_build_object(
                       'cif', t.ute_cif, 'nombre', t.nombre,
                       'contratos', t.n, 'importe_ute', t.euros,
                       'ultimo', t.ultimo,
                       'socios', (
                           select jsonb_agg(jsonb_build_object(
                                      'cif', o.socio_cif,
                                      'nombre', coalesce(e.nombre, o.socio_cif))
                                    order by e.nombre)
                           from public.ute_socios o
                           left join public.empresas e on e.cif = o.socio_cif
                           where o.ute_cif = t.ute_cif and o.socio_cif <> limpio))
                     order by t.ultimo desc nulls last)
            from (
                select s.ute_cif,
                       (array_agg(a.nombre order by a.fecha desc nulls last))[1] as nombre,
                       count(*)::int as n,
                       coalesce(sum(a.importe), 0) as euros,
                       max(a.fecha) as ultimo
                from public.ute_socios s
                join public.adjudicaciones_empresa a on a.cif = s.ute_cif
                where s.socio_cif = limpio
                  and not a.es_menor and not a.es_homologacion
                  and public.en_periodo(a.fecha, desde, hasta)
                group by s.ute_cif
                order by max(a.fecha) desc nulls last
                limit 30
            ) t
        ),
        'socios', (
            select jsonb_agg(jsonb_build_object(
                       'cif', o.socio_cif,
                       'nombre', coalesce(e.nombre, o.socio_cif))
                     order by e.nombre)
            from public.ute_socios o
            left join public.empresas e on e.cif = o.socio_cif
            where o.ute_cif = limpio
        )
    );
end;
$function$;

revoke execute on function public.utes_y_socios(text, integer, integer) from public, anon;
grant execute on function public.utes_y_socios(text, integer, integer) to authenticated;
