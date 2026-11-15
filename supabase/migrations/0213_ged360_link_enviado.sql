-- NIOGEN | supabase/migrations/0213_ged360_link_enviado.sql | 15/11/2026 — Claude Code (Opus 5.5)
-- O GED360 mostra "LINK ENVIADO" enquanto o cliente não fez a biometria (caso Caique/Grace, 15/11). Fora do mapa, cada leitura
-- gravava um erro "ged360_desconhecido" e a biometria não aparecia como "aguardando". Entra como espera.
-- Regra 20: o prazo dessa espera já é cuidado pela cadência (BIO1 · BIO3) e pelo "Link expirado" do próprio GED360.
begin;
insert into public.config_biometria_resultado (parceiro_id, resultado, acao, nivel, texto, rotulo)
values ('dharma', 'LINK ENVIADO', 'espera', null, 'link enviado · aguardando o cliente fazer a biometria', 'Link enviado')
on conflict do nothing;
update public.nio_biometria set desconhecido = false where resultado = 'LINK ENVIADO' and desconhecido;
commit;
