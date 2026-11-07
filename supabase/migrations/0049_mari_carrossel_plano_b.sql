-- NIOGEN | supabase/migrations/0049_mari_carrossel_plano_b.sql | 06/11/2026 — Claude Code (prompt 26 D, teste real no celular do Ricardo)
-- Teste real (06/11 ~22h30): o Chatwoot entrega só o TÍTULO do botão do carrossel ("Eu quero!", "Mais detalhes"), sem o id
-- — não dá para saber qual cartão foi tocado. Plano B APROVADO pelo Ricardo (06/11 18h42, spec §8): títulos com o nome do
-- plano (≤ 20 caracteres). O 2 · Entrada lê "Quero o <plano>" e o 5b · Motor responde "Detalhes <plano>" com o texto fixo.
update public.config_mari_carrossel k
   set titulo_quero    = 'Quero o ' || x.nome,
       titulo_detalhes = 'Detalhes ' || x.nome,
       atualizado_em   = now()
  from (values ('V-REG-FIBRA', 'Fibra'), ('V-REG-ESS', 'Essencial'), ('V-REG-SUP', 'Super'), ('V-REG-ULT', 'Ultra')) as x(codigo, nome)
 where k.plano_codigo = x.codigo;
