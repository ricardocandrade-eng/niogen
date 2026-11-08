-- NIOGEN | supabase/migrations/0066_motivo_pendencia_outro_cpf.sql | 08/11/2026 — Claude Code (pedido do Ricardo)
-- Por quê: quando a análise de crédito da Nio reprova o CPF, o backoffice pergunta ao cliente se ele tem OUTRO CPF (familiar ou
-- amigo) para tentar de novo; enquanto o cliente não responde, a venda fica pendenciada. Os motivos da 0064 não cobriam esse caso
-- (`cadastro_nio` é travamento do lado da Nio; aqui quem destrava é o CLIENTE).
-- O quê: só config (regra 15) — motivo `credito_outro_cpf`, quem destrava = cliente, saída sugerida = "Crédito negado"
-- (texto exato da lista de motivos de Saída da ficha). O texto para o cliente está no Guia do Backoffice (§3.5).

insert into public.config_motivos_pendencia (codigo, nome, quem_destrava, saida_sugerida, exige_descricao, ordem) values
  ('credito_outro_cpf', 'Crédito negado · aguardando outro CPF', 'cliente', 'Crédito negado', false, 5)
on conflict (codigo) do nothing;
