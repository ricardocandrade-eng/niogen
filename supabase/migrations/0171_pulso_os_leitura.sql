-- NIOGEN | 0171_pulso_os_leitura.sql | 13/11/2026 — Claude Code (docs/Prompt_operador_os_etapa3_131126_0300.md, etapa 3d)
-- Sinal de vida da rotina do Operador de OS no pulso. O workflow os_leitura (n8n, YLPf7oLAbIM6YVeq) não guarda execução com
-- sucesso; para ele o pulso mostra "ligado + sem erro recente". Trava acionada no operador ou volta sem nenhuma leitura boa
-- fazem a execução falhar de propósito — é isso que aparece aqui.
insert into public.pulso_batimentos (fluxo, workflow_id, descricao, roda, critico, intervalo_esperado_min, janela_inicio, janela_fim, dias_semana)
values ('os_leitura', 'YLPf7oLAbIM6YVeq', 'lê no portal da Nio o andamento das OS (Operador de OS)', 'a cada 30 min, 7h–20h30', false, 30, '07:00', '20:59', null)
on conflict (parceiro_id, fluxo) do nothing;
