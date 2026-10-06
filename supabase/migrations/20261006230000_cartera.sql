-- ============================================================
-- Mi cartera: llevar la cuenta de cada contrato
-- ============================================================
--
-- Prioridad 3 de la hoja de ruta (docs/competencia/LEEME.md) y
-- Decisión 53. Sin esto, el cliente que decide presentarse se lleva el
-- contrato a un Excel y deja de entrar: la lista solo enseña lo abierto,
-- y lo que ya ha presentado desaparece de ella al cerrar el plazo.
--
-- LOS ESTADOS (seis, no los doce de Licitandum)
--   interesa    Me interesa: guardado para mirarlo
--   preparando  Preparo la oferta: me presento
--   presentada  Oferta presentada: esperando resultado
--   ganada      Ganada
--   perdida     Perdida
--   descartada  No me presento: lo he mirado y no voy (el "no-go")
-- El Vínculo usa cinco columnas parecidas (en revisión, candidata, en
-- curso, presentada, ganada) más "descartada"; Licitandum, doce etapas y
-- un registro de go/no-go con motivo. Para una pyme que lleva una o dos
-- ofertas a la vez, seis bastan. El motivo del "no voy" va en la nota.
--
-- "No me presento" NO es "no me interesa": el contrato encaja, pero no
-- compensa (plazo, solvencia, competencia). No enseña nada al filtro.
--
-- QUÉ SE GUARDA POR CONTRATO
--   estado, una nota libre y, si quiere, el importe de su oferta. Con el
--   importe, cuando salga la adjudicación se compara con la ganadora:
--   "la ganadora ofertó un 6 % menos que tú". Es lo que ningún
--   competidor hace solo, y sale de datos que ya tenemos.
--
-- EL RESULTADO LLEGA SOLO
--   El feed trae la adjudicación con el NIF de cada adjudicatario, lote
--   a lote. `mi_cartera()` lo cruza con el NIF del perfil (y con las
--   UTE de las que es socio, `ute_socios`) y dice "La has ganado" o a
--   quién se adjudicó. No escribe el estado: lo propone y el cliente lo
--   confirma con un clic. Medido el 06/10/2026: de los contratos que
--   salieron en las listas con plazo en septiembre, 18 ya están
--   adjudicados con NIF y 608 en evaluación, así que el resultado irá
--   llegando a los pocos meses de cerrar el plazo.
--
-- "SÍ ME INTERESA" GUARDA EN LA CARTERA
--   Guardar algo es decir que interesa, así que `poner_en_cartera`
--   apunta también la corrección positiva (si no la había), igual que el
--   botón "Sí me interesa", y devuelve cuántas quedan sin aplicar para
--   que la web ajuste el filtro a las tres, como siempre. Los "sí me
--   interesa" que ya había en contratos abiertos (6 el 06/10/2026)
--   entran en la cartera como "Me interesa".
--
-- REPUBLICACIONES
--   Si el organismo republica el expediente con otro identificador, la
--   copia guardada queda `sustituida`. `mi_cartera()` enseña los datos
--   de la copia vigente (mismo órgano y expediente), que es la que trae
--   el plazo bueno, y lo dice.
--
-- PLAZO CAMBIADO
--   `plazo_visto` es el plazo que el cliente tenía cuando lo guardó o lo
--   tocó por última vez. Si el organismo lo amplía, la web lo dice hasta
--   que lo da por visto (`plazo_visto`).
--
-- No toca `mis_oportunidades` ni `licitaciones`: la web cruza la lista
-- con la cartera por su cuenta.
-- ============================================================

create table if not exists public.cartera (
    perfil_id      uuid not null references public.perfiles(id) on delete cascade,
    id_licitacion  text not null,
    estado         text not null check (estado in
                     ('interesa', 'preparando', 'presentada',
                      'ganada', 'perdida', 'descartada')),
    nota           text check (char_length(nota) <= 2000),
    importe_oferta numeric check (importe_oferta >= 0),
    plazo_visto    timestamptz,
    creado         timestamptz not null default now(),
    cambiado       timestamptz not null default now(),
    primary key (perfil_id, id_licitacion)
);

comment on table public.cartera is
  'Los contratos que cada perfil lleva: estado, nota e importe de su '
  'oferta. Se escribe solo con poner_en_cartera, anotar_en_cartera, '
  'quitar_de_cartera y dar_plazo_por_visto (Decisión 53).';

-- Para el aviso de plazos del correo diario, que recorre todos los
-- perfiles.
create index if not exists idx_cartera_estado
    on public.cartera (estado, perfil_id);

alter table public.cartera enable row level security;
revoke all on public.cartera from anon, authenticated;
grant select on public.cartera to authenticated;

drop policy if exists "cartera propia: leer" on public.cartera;
create policy "cartera propia: leer" on public.cartera
    for select to authenticated
    using (exists (select 1 from public.perfiles p
                   where p.id = cartera.perfil_id
                     and p.usuario_id = (select auth.uid())));


-- ------------------------------------------------------------
-- Escribir
-- ------------------------------------------------------------

-- Guarda o cambia el estado de un contrato. Devuelve la fila y cuántas
-- correcciones quedan sin aplicar (para ajustar el filtro a las tres).
create or replace function public.poner_en_cartera(licitacion text, nuevo_estado text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    perfil     uuid := public.mi_perfil_id();
    datos      public.licitaciones%rowtype;
    fila       public.cartera%rowtype;
    pendientes int;
begin
    if perfil is null then
        return jsonb_build_object('ok', false, 'error', 'sin_perfil');
    end if;
    if nuevo_estado is null or nuevo_estado not in
       ('interesa', 'preparando', 'presentada', 'ganada', 'perdida', 'descartada') then
        return jsonb_build_object('ok', false, 'error', 'estado');
    end if;

    select * into datos from public.licitaciones where id_licitacion = licitacion;
    if not found then
        return jsonb_build_object('ok', false, 'error', 'no_existe');
    end if;

    -- Tope holgado: una pyme lleva decenas, no miles. Evita que un
    -- bucle en la consola llene la tabla.
    if not exists (select 1 from public.cartera
                   where perfil_id = perfil and id_licitacion = licitacion)
       and (select count(*) from public.cartera where perfil_id = perfil) >= 1000 then
        return jsonb_build_object('ok', false, 'error', 'tope');
    end if;

    insert into public.cartera (perfil_id, id_licitacion, estado, plazo_visto)
    values (perfil, licitacion, nuevo_estado, datos.fecha_limite)
    on conflict (perfil_id, id_licitacion) do update
    set estado = excluded.estado,
        cambiado = now()
    returning * into fila;

    -- Guardar es decir que interesa. Solo si no había corrección: un
    -- "no me interesa" anterior no se pisa desde aquí (la web no deja
    -- guardar lo descartado, porque ya no sale en la lista).
    insert into public.correcciones
        (perfil_id, id_licitacion, titulo, organo, interesa)
    values (perfil, licitacion, datos.titulo, datos.organo, true)
    on conflict (perfil_id, id_licitacion) do nothing;

    select count(*) into pendientes
    from public.correcciones
    where perfil_id = perfil and not aplicada;

    return jsonb_build_object('ok', true, 'pendientes', pendientes,
                              'estado', fila.estado);
end;
$function$;

-- La nota y el importe de la oferta. Se mandan los dos siempre: lo que
-- llega vacío se borra.
create or replace function public.anotar_en_cartera(licitacion text, texto text,
                                                    importe numeric)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    perfil uuid := public.mi_perfil_id();
begin
    if perfil is null then
        return jsonb_build_object('ok', false, 'error', 'sin_perfil');
    end if;
    if importe is not null and importe < 0 then
        return jsonb_build_object('ok', false, 'error', 'importe');
    end if;

    update public.cartera
    set nota = nullif(left(trim(coalesce(texto, '')), 2000), ''),
        importe_oferta = importe,
        cambiado = now()
    where perfil_id = perfil and id_licitacion = licitacion;

    if not found then
        return jsonb_build_object('ok', false, 'error', 'no_esta');
    end if;
    return jsonb_build_object('ok', true);
end;
$function$;

-- Sacar un contrato de la cartera. No toca la corrección: sigue
-- interesando, solo que ya no lo lleva.
create or replace function public.quitar_de_cartera(licitacion text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    perfil uuid := public.mi_perfil_id();
begin
    if perfil is null then
        return jsonb_build_object('ok', false, 'error', 'sin_perfil');
    end if;
    delete from public.cartera
    where perfil_id = perfil and id_licitacion = licitacion;
    return jsonb_build_object('ok', true);
end;
$function$;

-- El cliente ha visto que el plazo cambió: deja de avisarse.
create or replace function public.dar_plazo_por_visto(licitacion text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    perfil uuid := public.mi_perfil_id();
begin
    if perfil is null then
        return jsonb_build_object('ok', false, 'error', 'sin_perfil');
    end if;
    update public.cartera
    set plazo_visto = (public.licitacion_vigente(licitacion)).fecha_limite
    where perfil_id = perfil and id_licitacion = licitacion;
    return jsonb_build_object('ok', true);
end;
$function$;


-- ------------------------------------------------------------
-- La copia vigente de una licitación
-- ------------------------------------------------------------
--
-- La misma regla que `marcar_sustituidas`: por órgano y expediente vale
-- la de actualización más reciente y, a igualdad, el identificador
-- mayor. Si la guardada no está sustituida, es ella misma.
create or replace function public.licitacion_vigente(licitacion text)
returns public.licitaciones
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
    guardada public.licitaciones%rowtype;
    vigente  public.licitaciones%rowtype;
begin
    select * into guardada from public.licitaciones where id_licitacion = licitacion;
    if not found or not coalesce(guardada.sustituida, false) then
        return guardada;
    end if;
    -- Por índice (idx_licitaciones_organo_expediente).
    select * into vigente
    from public.licitaciones x
    where x.organo = guardada.organo and x.expediente = guardada.expediente
      and not x.sustituida
    order by x.fecha_actualizacion desc nulls last, x.id_licitacion desc
    limit 1;
    if found then return vigente; end if;
    return guardada;
end;
$function$;

revoke execute on function public.licitacion_vigente(text) from public, anon, authenticated;


-- ------------------------------------------------------------
-- El resultado de una licitación para un NIF
-- ------------------------------------------------------------
--
-- Lote a lote, de `adjudicaciones`; sin ese detalle, de las columnas
-- de la licitación. `tuyo` si el adjudicatario es el NIF o una UTE de la
-- que es socio.
--
-- resultado:
--   tuya       algún lote es suyo
--   otra       adjudicada (algún lote) a otras empresas
--   desierta   todos los lotes desiertos
--   retirada   anulada, o el organismo desistió o renunció
--   null       todavía no hay nada
create or replace function public.resultado_licitacion(l public.licitaciones, mi_cif text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
    with lotes as (
        select (e->>'lote')                              as lote,
               nullif(trim(e->>'adjudicatario'), '')     as empresa,
               nullif(trim(e->>'cif'), '')               as cif,
               (e->>'importe')::numeric                  as importe,
               nullif((e->>'licitadores')::numeric::int, 0)       as licitadores,
               nullif((e->>'oferta_baja')::numeric, 0)   as oferta_baja,
               nullif((e->>'oferta_alta')::numeric, 0)   as oferta_alta,
               coalesce(e->>'resultado', '')             as resultado,
               nullif(e->>'fecha', '')::date             as fecha
        from jsonb_array_elements(case when jsonb_typeof(l.adjudicaciones) = 'array'
                                       then l.adjudicaciones else '[]'::jsonb end) e
        union all
        -- Sin detalle por lotes: lo que diga la licitación.
        select null, l.adjudicatario, l.adjudicatario_cif, l.importe_adjudicacion,
               nullif(l.licitadores, 0), l.oferta_baja, l.oferta_alta, '',
               l.fecha_adjudicacion
        where jsonb_typeof(l.adjudicaciones) is distinct from 'array'
           or jsonb_array_length(l.adjudicaciones) = 0
    ),
    marcados as (
        select lo.*,
               mi_cif is not null and lo.cif is not null
               and (lo.cif = mi_cif
                    or exists (select 1 from public.ute_socios u
                               where u.ute_cif = lo.cif and u.socio_cif = mi_cif))
                 as tuyo,
               mi_cif is not null and lo.cif is not null and lo.cif <> mi_cif
               and exists (select 1 from public.ute_socios u
                           where u.ute_cif = lo.cif and u.socio_cif = mi_cif)
                 as en_ute,
               (lo.empresa is not null or lo.cif is not null) as con_ganador
        from lotes lo
    )
    select case
        when l.estado_licitacion = 'ANUL' then jsonb_build_object('resultado', 'retirada')
        when not exists (select 1 from marcados)
             or coalesce(l.estado_licitacion, '') not in ('ADJ', 'RES')
          then case when l.estado_licitacion = 'EV'
                    then jsonb_build_object('resultado', null, 'evaluando', true)
                    else null end
        else jsonb_build_object(
            'resultado',
                case when bool_or(m.tuyo) then 'tuya'
                     when bool_or(m.con_ganador) then 'otra'
                     when bool_and(m.resultado = 'desierto') then 'desierta'
                     when bool_and(m.resultado in ('desistimiento', 'renuncia', 'desierto'))
                       then 'retirada'
                     else null end,
            'fecha', max(m.fecha),
            'lotes', count(*),
            'ganadores', coalesce(jsonb_agg(jsonb_build_object(
                    'lote', m.lote, 'empresa', coalesce(m.empresa, m.cif),
                    'cif', m.cif, 'importe', m.importe,
                    'licitadores', m.licitadores,
                    'oferta_baja', m.oferta_baja, 'oferta_alta', m.oferta_alta,
                    'tuyo', m.tuyo, 'en_ute', m.en_ute)
                  order by m.tuyo desc, m.importe desc nulls last)
                  filter (where m.con_ganador), '[]'::jsonb))
        end
    from marcados m
$function$;

revoke execute on function public.resultado_licitacion(public.licitaciones, text)
    from public, anon, authenticated;


-- ------------------------------------------------------------
-- Leer: la cartera de la empresa activa
-- ------------------------------------------------------------
create or replace function public.mi_cartera()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
    select coalesce(jsonb_agg(jsonb_build_object(
        'id_licitacion',   c.id_licitacion,
        'estado',          c.estado,
        'nota',            c.nota,
        'importe_oferta',  c.importe_oferta,
        'creado',          c.creado,
        'cambiado',        c.cambiado,
        'plazo_visto',     c.plazo_visto,
        'republicada',     v.id_licitacion is not null
                           and v.id_licitacion <> c.id_licitacion,
        'titulo',          v.titulo,
        'organo',          v.organo,
        'provincia',       v.provincia,
        'comunidad',       v.comunidad,
        'presupuesto',     v.presupuesto,
        'presupuesto_base', v.presupuesto_base,
        'duracion_meses',  v.duracion_meses,
        'enlace',          v.enlace,
        'fecha_limite',    v.fecha_limite,
        'estado_licitacion', v.estado_licitacion,
        'sistema',         v.sistema,
        'viabilidad',      case
            when g.veredicto is null or g.veredicto in ('sin_datos', 'error') then null
            when g.serie and p.cif is not null and g.ultimo_cif = p.cif then 'mio'
            else g.veredicto end,
        'adjudicacion',    public.resultado_licitacion(v, p.cif)
      ) order by c.cambiado desc), '[]'::jsonb)
    from public.perfiles p
    join public.cartera c on c.perfil_id = p.id
    left join lateral public.licitacion_vigente(c.id_licitacion) v on true
    left join public.viabilidad_guardada g on g.id_licitacion = v.id_licitacion
    where p.id = public.mi_perfil_id()
$function$;


-- ------------------------------------------------------------
-- Para el correo diario: los plazos que se acercan
-- ------------------------------------------------------------
--
-- Lo que lleva "Me interesa" o "Preparo la oferta" y cierra en los
-- próximos 8 días, todavía abierto. Cuáles se avisan (a 7, 3 y 1 día,
-- como Licitandum) lo decide `alertador.py`, que ya cuenta los días en
-- hora peninsular.
create or replace function public.plazos_de_cartera(perfil uuid)
returns table(id_licitacion text, titulo text, organo text, provincia text,
              codigo_postal text, presupuesto numeric, enlace text,
              fecha_limite timestamptz, estado text)
language sql
stable
security definer
set search_path to 'public'
as $function$
    select v.id_licitacion, v.titulo, v.organo, v.provincia, v.codigo_postal,
           v.presupuesto, v.enlace, v.fecha_limite, c.estado
    from public.cartera c
    cross join lateral public.licitacion_vigente(c.id_licitacion) v
    where c.perfil_id = perfil
      and c.estado in ('interesa', 'preparando')
      and coalesce(v.estado_licitacion, '') = 'PUB'
      and v.fecha_limite >= now()
      and v.fecha_limite < now() + interval '8 days'
    order by v.fecha_limite
$function$;


-- ------------------------------------------------------------
-- Permisos
-- ------------------------------------------------------------
revoke execute on function public.poner_en_cartera(text, text) from public, anon;
revoke execute on function public.anotar_en_cartera(text, text, numeric) from public, anon;
revoke execute on function public.quitar_de_cartera(text) from public, anon;
revoke execute on function public.dar_plazo_por_visto(text) from public, anon;
revoke execute on function public.mi_cartera() from public, anon;
grant execute on function public.poner_en_cartera(text, text) to authenticated;
grant execute on function public.anotar_en_cartera(text, text, numeric) to authenticated;
grant execute on function public.quitar_de_cartera(text) to authenticated;
grant execute on function public.dar_plazo_por_visto(text) to authenticated;
grant execute on function public.mi_cartera() to authenticated;

revoke execute on function public.plazos_de_cartera(uuid) from public, anon, authenticated;
grant execute on function public.plazos_de_cartera(uuid) to service_role;


-- ------------------------------------------------------------
-- Lo que ya había: los "sí me interesa" en contratos abiertos
-- ------------------------------------------------------------
insert into public.cartera (perfil_id, id_licitacion, estado, plazo_visto, creado, cambiado)
select c.perfil_id, c.id_licitacion, 'interesa', l.fecha_limite, c.fecha, c.fecha
from public.correcciones c
join public.licitaciones l on l.id_licitacion = c.id_licitacion
where c.interesa
  and coalesce(l.estado_licitacion, '') = 'PUB'
  and (l.fecha_limite is null or l.fecha_limite >= now())
  and not l.sustituida
on conflict (perfil_id, id_licitacion) do nothing;
