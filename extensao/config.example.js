/* NIOGEN | extensao/config.example.js | 06/11/2026 — prompt 28
 * Copie para extensao/config.js (fora do git — igual ao docs/config.js do site) e preencha com o MESMO projeto Supabase Nio.
 * Só a chave ANON (pública por natureza; quem protege os dados é o RLS + o login do usuário do NIOGEN). A service role NUNCA entra aqui.
 * Se mudar a URL do Supabase, ajuste também "host_permissions" no manifest.json.
 */
window.NIOGEN_CONFIG = {
  supabaseUrl: 'https://SEU-PROJETO.supabase.co',
  supabaseAnonKey: 'COLE-AQUI-A-CHAVE-ANON',
};
