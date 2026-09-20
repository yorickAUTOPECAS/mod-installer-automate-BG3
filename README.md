# Party Limit Begone — Instalador Automático (Baldur's Gate 3)

Instalador de **um clique** do mod [Party Limit Begone](https://www.nexusmods.com/baldursgate3/mods/327) (por **Sildur**) para Baldur's Gate 3. Feito para grupos de amigos: **todo mundo executa o mesmo arquivo e fica com a instalação idêntica** — sem depender de ninguém acertar a instalação na mão.

> **Para os amigos:** baixem o `install.bat`, deem **2 cliques**, aguardem, e quando aparecer **TUDO PRONTO**, apertem ENTER para abrir o jogo. É só isso. 🐹

---

## O que o `install.bat` faz (sozinho, sem perguntar nada)

1. **Encontra a pasta do jogo automaticamente** — Steam (registro + bibliotecas), GOG (registro), Epic (manifests), caminhos comuns em todos os discos e, em último caso, varredura completa dos discos. Só pergunta caminho se TUDO falhar.
2. **Confere se o jogo está fechado** (instalar com o jogo aberto estraga o patch).
3. **Instala o Standalone v3.5** — copia as 9 pastas do mod para `Data\Mods\` (limite de 16 membros no grupo).
4. **Aplica o patch de multiplayer** direto nos bytes do `bg3.exe` **e** do `bg3_dx11.exe` (Vulkan e DX11) — até 8 jogadores online. Sem editor hexadecimal, sem risco de Windows Defender reclamar (nada de XVI32).
5. **Cria backup de cada exe** antes de mexer (`bg3.exe.backup`).
6. **Se algo já foi tentado antes e deu errado**, ele conserta:
   - exe parcialmente patcheado → completa o patch;
   - backup "envenenado" (feito a partir de um exe já patcheado) → detecta e substitui;
   - pastas/arquivos do PLB nos lugares errados (zip extraído dentro de `Data\Mods`, `.pak` solto, etc.) → move para **quarentena** (nada é apagado!);
   - mods de outras pessoas → **não são tocados** (o instalador só mexe em arquivos que ele reconhece como do PLB).
7. **Verifica tudo no final** e mostra um resumo com ✅. Se o jogo atualizou e o mod ainda não tem patch para a nova versão, ele **aborta sem modificar nada** e explica o que fazer.
8. Pede permissão de administrador **só se precisar** (janela do UAC — clique em "Sim").

**Nada é baixado durante a instalação.** Os dois zips do mod e toda a lógica estão embutidos dentro do próprio `install.bat`. Sem login no Nexus, sem seção, sem internet no meio do caminho.

## Como distribuir

Envie para os amigos (WhatsApp, Discord, ou o link de download do GitHub):

```
install.bat     (apenas este arquivo, ~0,8 MB)
```

Instruções para leigos:

> 1. Baixe o arquivo `install.bat`.
> 2. Dê 2 cliques nele. Se o Windows mostrar uma tela azul, clique em **"Mais informações"** e depois em **"Executar assim mesmo"**.
> 3. Se aparecer uma janela pedindo permissão, clique em **"Sim"**.
> 4. Espere aparecer **TUDO PRONTO** e aperte ENTER para abrir o jogo. 🎮
>
> ⚠️ **Todo mundo do grupo precisa rodar o instalador**, senão o multiplayer com mais de 4 jogadores não funciona.

## Reversão (se um dia precisar)

Rode o `uninstall.bat` (também de um clique): ele restaura os executáveis a partir dos backups e remove **somente** os arquivos do PLB (reconhecidos pelo UUID do mod — mods de terceiros permanecem intactos). Alternativa "bruta": Steam → Baldur's Gate 3 → Propriedades → Arquivos instalados → **Verificar integridade dos arquivos**.

## Limites conhecidos do mod (do autor)

- **Grymforge**: reduza o grupo para 4 antes de usar o barco.
- Itens de missão carregados pelo 5º+ membro podem não ser registrados — deixe itens importantes com os 4 primeiros.
- Alguns eventos são fixados em 4 membros pelo jogo; dispensar membros ou teleportar resolve.
- Jogadores 5+ entram por código direto (host com porta 23253 aberta) ou modo LAN (Hamachi/Radmin). Detalhes no readme do autor.

---

## Para você (mantenedor)

### Estrutura

```
install.bat              ← gerado. O arquivo que você distribui (autocontido)
uninstall.bat            ← gerado. Desinstalador de um clique
src/install.ps1          ← código-fonte (lógica completa)
files/*.zip              ← os zips originais do Nexus (fonte da verdade)
make-installer.ps1       ← regenera os .bat a partir de src/ + files/
tests/run-tests.ps1      ← bateria de testes (46 asserções)
README.md                ← este arquivo
```

### Como atualizar o mod no futuro

1. Baixe os zips novos do Nexus e substitua os arquivos em `files/` (mantenha "Standalone"/"Multiplayer" nos nomes).
2. Rode: `powershell -NoProfile -ExecutionPolicy Bypass -File make-installer.ps1`
3. Confirme e suba os `install.bat`/`uninstall.bat` novos. Avise o pessoal para baixar de novo.

### Como testar mudanças

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File make-installer.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

Os testes usam "jogos falsos" em pasta temporária e têm **guarda de sandbox**: eles se recusam a rodar contra qualquer pasta fora do ambiente de teste. O instalador também entende `PLB_DISABLE_AUTODETECT=1` (não escaneia discos/registro), usado pelos testes.

### Detalhes técnicos

- Os `.bat` são gerados embutindo o script PowerShell + os 2 zips **em base64** (texto seguro para o `cmd.exe`), reconstituído e executado via `Invoke-Expression` com `powershell.exe` nativo do Windows 10/11 (sem dependências).
- O patch de multiplayer aplica os 8 padrões de bytes do `PLB-MP-Patch.xsc` do autor (mesmo resultado do XVI32, sem editor hexadecimal e sem o falso positivo que o Defender dava no executável dele).
- Estados dos exes: `ORIGINAL`, `PARTIAL` (completa o patch), `PATCHED` (pula), `UNKNOWN` (versão nova do jogo → aborta sem escrever; se houver backup limpo, restaura e repatcheia sobre ele).
- Quarentena + manifesto (`PLB-Installer-Backup\manifest.json` + `instalador.log`) registram tudo que foi feito, instalado e movido.
- Créditos: mod por **Sildur** — https://www.nexusmods.com/baldursgate3/mods/327
