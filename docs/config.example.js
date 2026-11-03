/* NIOGEN | docs/config.example.js | 03/11/2026
 * Copie para docs/config.js (fora do git) e preencha com o projeto Supabase Nio.
 * Só a chave ANON entra aqui: ela é pública por natureza e quem protege os dados é o RLS.
 * A service role NUNCA vai para o front.
 * No GitHub Pages o config.js é gerado pelo workflow a partir de SUPABASE_NIO_URL (variable) e SUPABASE_NIO_ANON (secret).
 */
window.NIOGEN_CONFIG = {
  supabaseUrl: 'https://SEU-PROJETO.supabase.co',
  supabaseAnonKey: 'COLE-AQUI-A-CHAVE-ANON',
};
