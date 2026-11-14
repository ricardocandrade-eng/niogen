-- NIOGEN | supabase/migrations/0192_template_cartao.sql | 14/11/2026 — Claude Code (Opus 5.5)
-- 0194: biometria aprovada + pagamento no cartão → a Mari avisa do link do cadastro do cartão (passos CARTAO e CARTAO2 da cadência).
-- Com a janela de 24 h aberta sai o texto livre (config_mari_textos mari_cartao_aviso / mari_cartao_lembrete); fechada, este template.
-- Parâmetros: {{1}} nome · {{2}} dia ("segunda-feira, 16/11") · {{3}} período ("tarde, 13h às 17h"). Submeter: python n8n/waba_template_cartao.py --enviar
insert into public.config_templates_waba (nome, categoria, idioma, corpo, botoes, rodape, status, uso)
values ('nio_cartao_cadastro', 'UTILITY', 'pt_BR',
'Oi, {{1}}! É a Mari, da Nio 👋

Sua biometria foi aprovada. Como o pagamento é no cartão de crédito, a Nio te mandou por WhatsApp e por e-mail um link para cadastrar o cartão, no ambiente da própria Nio (por aqui a gente nunca pede os dados do cartão).

Esse cadastro é o último passo para confirmar a visita do técnico em {{2}}, {{3}}. Se não achar a mensagem, confere o spam ou me chama por aqui que o nosso time ajuda 😊',
  '["Preciso de ajuda"]'::jsonb, null, 'PENDING', 'CARTAO')
on conflict (nome) do nothing;
