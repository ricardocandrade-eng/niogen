-- NIOGEN | supabase/migrations/0306_midia_cadencia_para_todos.sql | 19/11/2026 — Claude Code
-- Resumo: libera a mídia dos lembretes da cadência para TODOS os leads (Ricardo, 19/11/2026: "Liberar para todos").
--   Até aqui só os telefones de teste recebiam (0146/0152): imagem do plano no F2 e voz no F3 (n8n/cadencia/c06m_midia.js).
--   '' = todos os telefones. A/B segue desligado (midia_cadencia_ab = 'nao'): todo lead no F2/F3 recebe a mídia.
--   Travas que continuam no c06m: só cutucada escrita (F1–F5, texto livre na janela de 24 h); voz recusa texto > 250
--   caracteres, preço, número longo ou link (vai em texto); sem imagem do plano → texto. Cada envio fica em mari_midia_envios.
--   Cinco regras (regra 20): não cria situação, evento, estado nem tabela — só muda o canal de uma mensagem que já saía;
--   a contagem já existe em mari_midia_envios. Nenhuma conferência nova necessária.
--   Para voltar: update config_mari_textos set texto = 'teste' where chave = 'midia_cadencia_telefones';
begin;

update public.config_mari_textos set texto = '' where chave = 'midia_cadencia_telefones';

commit;
