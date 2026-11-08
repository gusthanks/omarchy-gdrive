# Por que (e como) criar o seu próprio `client_id` do Google

> 🇺🇸 [English version](own-client-id.md)

## Por quê

Quando o rclone fala com o Google Drive, ele precisa dizer *qual aplicativo*
está pedindo. Essa identidade é um **client_id** OAuth. De fábrica, toda cópia
do rclone no planeta usa o **mesmo client_id compartilhado** que o projeto
rclone registrou anos atrás.

Isso traz dois problemas:

1. **É lento.** O Google dá uma cota para cada client_id. Um client_id
   dividido entre milhões de usuários significa erros `rateLimitExceeded`
   constantes, listagem de pastas lenta e uploads que travam.
2. **Vai acabar.** O Google está aposentando esse cliente compartilhado durante
   **2026**. O rclone já mostra um aviso em todo comando. Quando ele parar de
   funcionar, os mounts que ainda dependem dele param junto.

Criar o seu leva uns cinco minutos, é grátis, e te dá uma faixa privada com a
sua própria cota. Você não precisa entender OAuth.

### O que você vai ter no final

| Valor | O que é | Onde fica |
|---|---|---|
| `client_id` | Identificador público do "seu rclone", termina em `.apps.googleusercontent.com` | `~/.config/rclone/rclone.conf` |
| `client_secret` | Uma senha para esse identificador | `~/.config/rclone/rclone.conf` (modo 600) |
| token | Seu login de verdade, criado quando você entra na conta | `~/.config/rclone/rclone.conf` (modo 600) |

O omarchy-gdrive nunca imprime, registra em log nem envia nenhum desses
valores. O secret é gravado direto no `rclone.conf`, então também nunca
aparece em linha de comando.

## Como

Os passos abaixo seguem o Google Cloud Console em inglês; as
mesmas telas existem em todos os idiomas.

### 1. Criar um projeto

1. Abra <https://console.cloud.google.com/projectcreate> e entre com a conta
   Google cujo Drive você quer montar.
2. **Nome do projeto:** qualquer um, ex. `Omarchy Drive`.
3. **Organização:** deixe *Sem organização* (é o padrão para contas pessoais
   `@gmail.com`).
4. Clique em **Criar**, espere a notificação e confira se o projeto novo está
   selecionado no seletor de projetos no topo.

<!-- screenshot: img/01-create-project.png — Criar projeto -->

### 2. Ativar a API do Google Drive

1. Abra <https://console.cloud.google.com/apis/library/drive.googleapis.com>.
2. Confira se o seu projeto novo está selecionado no topo.
3. Clique em **Ativar**.

<!-- screenshot: img/02-enable-drive-api.png — Ativar API do Drive -->

### 3. Configurar a tela de consentimento (Google Auth Platform)

1. Abra <https://console.cloud.google.com/auth/overview> e clique em **Começar**.
2. **Informações do app:** nome `Omarchy Drive`, e-mail de suporte = o seu.
3. **Público-alvo:** escolha **Externo**.
4. **Informações de contato:** seu e-mail de novo. Aceite a política, **Criar**.

<!-- screenshot: img/03-consent-screen.png — Tela de consentimento -->

### 4. Adicionar você mesmo como usuário de teste

O app fica em modo *Teste*, que é exatamente o que você quer: só as contas
listadas aqui conseguem usá-lo, e o Google não pede verificação nenhuma.

1. No menu da esquerda, abra **Público-alvo** (*Audience*).
2. Em **Usuários de teste**, clique em **+ Adicionar usuários**, digite seu
   e-mail do Google e **Salvar**.

<!-- screenshot: img/04-test-users.png — Usuários de teste -->

> Tokens de apps em modo Teste expiravam depois de 7 dias. Esse limite não se
> aplica mais ao tipo *App para computador* usado abaixo, e o rclone renova o
> token sozinho em segundo plano.

### 5. Criar o cliente OAuth

1. No menu da esquerda, abra **Clientes** e clique em **+ Criar cliente**.
2. **Tipo de aplicativo:** **App para computador** (*Desktop app*).
3. **Nome:** `rclone` (ou qualquer um).
4. Clique em **Criar**.
5. Na janela que abre, clique em **Fazer o download do JSON**. Um arquivo
   chamado `client_secret_<números>.json` vai para `~/Downloads`.

<!-- screenshot: img/05-create-client.png — Criar cliente OAuth -->
<!-- screenshot: img/06-download-json.png — Baixar JSON -->

Se aparecer *"Usar este cliente para um agente com IA"*, deixe desmarcado.

### 6. Entregar para o omarchy-gdrive

```bash
omarchy-gdrive setup
```

O setup encontra sozinho o `client_secret_*.json` mais novo em `~/Downloads`
e pede confirmação. Se você já tem um mount funcionando, ele oferece trocar
para o seu cliente novo:

```bash
omarchy-gdrive setup --client
```

Seu navegador abre uma vez na tela de consentimento do Google. Se aparecer
**"O Google não verificou este app"**, clique em **Avançado → Acessar Omarchy
Drive (não seguro)**. O app é *seu*; o aviso só quer dizer que você não passou
pelo processo de verificação do Google, desnecessário para uma ferramenta
privada.

Depois disso você pode apagar o JSON de `~/Downloads`: os valores já estão no
`rclone.conf`.

### 7. Conferir

```bash
omarchy-gdrive doctor
```

deve mostrar `O remote 'gdrive' usa seu próprio client_id OAuth`.

## Perguntas frequentes

**Custa alguma coisa?** Não. A API do Drive é gratuita para uso pessoal e este
projeto nunca precisa de faturamento ativado.

**Posso reaproveitar o cliente em outras máquinas?** Sim. Copie o mesmo
`client_id`/`client_secret` (ou o JSON) para a outra máquina e rode
`omarchy-gdrive setup --credentials <arquivo>`. Cada máquina faz login
separado e ganha o seu próprio token.

**Perdi o JSON.** No console, abra **Clientes**, clique no seu cliente e use
**Fazer o download do JSON** de novo, ou copie id e secret daquela página e
escolha *Colar client_id e client_secret à mão* no `omarchy-gdrive setup --client`.

**Quero revogar tudo.** <https://myaccount.google.com/permissions> lista o
app; remover ali invalida todos os tokens. Apagar o projeto no Cloud Console
remove o próprio cliente.
