-- ============================================================
-- RLS: EVALUAR auth.uid() UNA VEZ, NO POR FILA
-- ============================================================
--
-- Aplicada el 20/09/2026.
--
-- EL PROBLEMA
-- Postgres reevalúa `auth.uid()` FILA A FILA cuando aparece suelto en
-- una política. Envuelto en `(select auth.uid())` lo trata como
-- InitPlan y lo calcula una sola vez por consulta.
--
-- El significado de cada política NO cambia: mismas filas visibles,
-- mismas condiciones. Solo cambia cuándo se evalúa la llamada.
--
-- Se escriben los 16 ALTER POLICY uno a uno, en lugar de generarlos
-- con un replace de texto sobre pg_policies: reescribir políticas de
-- seguridad con una sustitución automática sin mirar el resultado es
-- exactamente como se abre un agujero.
--
-- Cuidado con la forma de cada una: INSERT solo admite WITH CHECK,
-- SELECT y DELETE solo USING, y UPDATE puede llevar las dos.
-- ============================================================

begin;

-- --- perfiles: la condición es directa, sin subconsulta ---

alter policy "perfil propio: leer" on public.perfiles
    using ((select auth.uid()) = usuario_id);

alter policy "perfil propio: crear" on public.perfiles
    with check ((select auth.uid()) = usuario_id);

alter policy "perfil propio: editar" on public.perfiles
    using ((select auth.uid()) = usuario_id)
    with check ((select auth.uid()) = usuario_id);


-- --- el resto cuelga de `perfiles` por perfil_id ---

alter policy "veredictos propios: leer" on public.veredictos
    using (exists (select 1 from public.perfiles p
                   where p.id = veredictos.perfil_id
                     and p.usuario_id = (select auth.uid())));

alter policy "mercado propio: leer" on public.veredictos_mercado
    using (exists (select 1 from public.perfiles p
                   where p.id = veredictos_mercado.perfil_id
                     and p.usuario_id = (select auth.uid())));

alter policy "correcciones propias: leer" on public.correcciones
    using (exists (select 1 from public.perfiles p
                   where p.id = correcciones.perfil_id
                     and p.usuario_id = (select auth.uid())));

alter policy "correcciones propias: crear" on public.correcciones
    with check (exists (select 1 from public.perfiles p
                        where p.id = correcciones.perfil_id
                          and p.usuario_id = (select auth.uid())));

alter policy "correcciones propias: editar" on public.correcciones
    using (exists (select 1 from public.perfiles p
                   where p.id = correcciones.perfil_id
                     and p.usuario_id = (select auth.uid())));

alter policy "ejemplos propios: leer" on public.ejemplos_entrenamiento
    using (exists (select 1 from public.perfiles p
                   where p.id = ejemplos_entrenamiento.perfil_id
                     and p.usuario_id = (select auth.uid())));

alter policy "ejemplos propios: crear" on public.ejemplos_entrenamiento
    with check (exists (select 1 from public.perfiles p
                        where p.id = ejemplos_entrenamiento.perfil_id
                          and p.usuario_id = (select auth.uid())));

alter policy "seguimiento propio: leer" on public.seguimiento
    using (exists (select 1 from public.perfiles p
                   where p.id = seguimiento.perfil_id
                     and p.usuario_id = (select auth.uid())));

alter policy "seguimiento propio: crear" on public.seguimiento
    with check (exists (select 1 from public.perfiles p
                        where p.id = seguimiento.perfil_id
                          and p.usuario_id = (select auth.uid())));

alter policy "seguimiento propio: borrar" on public.seguimiento
    using (exists (select 1 from public.perfiles p
                   where p.id = seguimiento.perfil_id
                     and p.usuario_id = (select auth.uid())));

alter policy "competencia propia" on public.competencia_guardada
    using (exists (select 1 from public.perfiles p
                   where p.id = competencia_guardada.perfil_id
                     and p.usuario_id = (select auth.uid())));

alter policy "organismos propios" on public.organismos_guardados
    using (exists (select 1 from public.perfiles p
                   where p.id = organismos_guardados.perfil_id
                     and p.usuario_id = (select auth.uid())));

alter policy "fichas propias" on public.fichas_organismo
    using (exists (select 1 from public.perfiles p
                   where p.id = fichas_organismo.perfil_id
                     and p.usuario_id = (select auth.uid())));

commit;

-- Comprobación: get_advisors(security/performance) no debe devolver
-- avisos `auth_rls_initplan`, y pg_policies debe seguir mostrando 20
-- políticas, todas atadas a auth.uid().
