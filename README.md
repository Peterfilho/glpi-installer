# GLPI Installer

Script Bash para automatizar a instalação do [GLPI](https://glpi-project.org/) em servidores Debian/Ubuntu (baseados em APT), com Apache, PHP e MariaDB.

## O que o script faz

1. **Detecta o sistema operacional** a partir de `/etc/os-release`, valida que é uma distro baseada em APT e identifica a família (Debian ou Ubuntu, incluindo derivados via `ID_LIKE`) para escolher o repositório de PHP adequado.
2. **Faz uma verificação inicial do ambiente** e mostra o que já existe no servidor: PHP (presença e versão), versões configuradas em `/etc/php`, Apache (presença, versão e se o serviço está ativo), servidor de banco (MariaDB ou MySQL, versão, serviço e se o root consegue conectar) e se o repositório de PHP já está configurado.
3. **Coleta as configurações da instalação** interativamente, com valores padrão sugeridos:
   - Versão do GLPI (padrão: `11.0.8`)
   - Versão do PHP (padrão: `8.2`, ou a versão já instalada quando existir uma)
   - Nome do banco de dados e usuário do GLPI
   - Senha do banco (gera uma senha aleatória com `openssl rand -hex 18`, ou permite informar uma)
   - Caminho de instalação (padrão: `/var/www/glpi`)
   - `ServerName` do Apache (opcional)
4. **Monta um plano de instalação** com 14 etapas, marcando cada uma como `install` ou `skip` conforme o que já está pronto no servidor (ver seção abaixo). O plano pode ser aceito como está ou ajustado etapa por etapa.
5. **Executa as etapas selecionadas**, cada uma isolada: se uma falha, as demais continuam. As etapas que dependem de uma etapa que falhou são marcadas como puladas em vez de tentadas.
6. **Salva as credenciais** em `/root/glpi-install-credentials.txt` (permissão `600`), registrando também o resultado da etapa de banco de dados.
7. **Mostra o ambiente final** (PHP, pacotes ainda faltando, Apache, banco e arquivos do GLPI) depois da execução.
8. **Exibe um relatório** com o resultado de cada etapa (`OK`, `FAIL` ou `SKIP`, com o motivo) e o total de sucessos, falhas e etapas puladas. O script sai com código `1` se alguma etapa falhou.
9. **Exibe o passo a passo final** apenas quando tudo o que é necessário ficou pronto, explicando que o GLPI ainda não está instalado (isso só acontece pelo assistente web) e o que fazer em seguida. Se algo essencial falhou, o script mostra quais etapas impedem o acesso pelo navegador.

Todo o processo é registrado em `/var/log/glpi-install.log`.

> **Importante:** o script **não** remove o diretório `install/` do GLPI. Essa remoção só pode
> acontecer depois de concluir o assistente de instalação pelo navegador. Removê-lo antes
> impede o GLPI de configurar idioma, licença e conexão com o banco pela interface web.

## Etapas e escolha do que instalar

O plano tem estas etapas, na ordem de execução:

| # | Etapa | Pulada por padrão quando |
|---|---|---|
| 1 | Atualizar as listas de pacotes do APT | nunca |
| 2 | Atualizar os pacotes do sistema (`apt-get upgrade`) | nunca |
| 3 | Instalar pacotes base (`curl`, `wget`, `unzip`, `gnupg`, etc.) | nunca |
| 4 | Configurar o repositório de PHP da distro | o PHP escolhido já está completo, ou não há repositório conhecido |
| 5 | Instalar PHP e as extensões do GLPI | todos os pacotes da versão escolhida já estão instalados |
| 6 | Instalar o Apache | o Apache já está instalado |
| 7 | Instalar o servidor MariaDB | já existe MariaDB ou MySQL instalado |
| 8 | Habilitar e iniciar Apache e banco de dados | nunca |
| 9 | Hardening básico do banco (equivalente ao `mysql_secure_installation`) | o servidor de banco já existia antes desta execução |
| 10 | Criar o banco e o usuário do GLPI | já existe `config/config_db.php` no caminho de instalação |
| 11 | Baixar e extrair o GLPI | a mesma versão do GLPI já está no caminho de instalação |
| 12 | Configurar o VirtualHost do Apache | nunca |
| 13 | Ajustar o `php.ini` para o GLPI | nunca |
| 14 | Aplicar as permissões dos arquivos do GLPI | nunca |

Depois de exibir o plano, o script pergunta se ele deve ser executado como está. Respondendo
`n`, é possível marcar `y` ou `n` para cada etapa individualmente e revisar o plano de novo
antes de confirmar.

Detalhes úteis:

- A etapa de PHP instala **apenas os pacotes que faltam** para a versão escolhida, incluindo
  `libapache2-mod-php`. O plano lista quais pacotes serão instalados.
- Os pacotes são divididos em obrigatórios e opcionais:
  - obrigatórios: `php`, `php-cli`, `php-common`, `curl`, `gd`, `mbstring`, `mysql`, `xml`,
    `intl`, `zip`, `bcmath` e `libapache2-mod-php`;
  - opcionais: `imap`, `ldap`, `soap`, `snmp`, `apcu` e `bz2`.

  Os opcionais são instalados um a um. Se a distro não fornecer algum deles (o caso mais
  comum é o `php-imap`, removido de versões recentes), ele é apenas reportado como aviso no
  relatório final, sem derrubar a etapa de PHP nem o resto da instalação.
- Se a versão de PHP escolhida não existir nos repositórios configurados, apenas a etapa de
  PHP falha (com a mensagem explicando o que fazer); o restante do plano continua.
- Se já existir um banco instalado e o root não conseguir conectar pelo socket local, o
  script pede a senha de root (até três tentativas) para poder criar o banco do GLPI.
- Uma instalação existente em `/var/www/glpi` nunca é apagada: se a etapa de download for
  executada, o diretório atual é movido para `<caminho>.backup.AAAAMMDDHHMMSS`.
- O plano avisa quando o usuário do banco já existe, porque nesse caso a etapa de banco
  redefine a senha dele para a informada nesta execução.

## Relatório e reexecução

No final, o script imprime uma linha por etapa:

```
[  OK  ] Update APT package lists
[ FAIL ] Install PHP 8.2 and extensions                 exit code 1
[ SKIP ] Install Apache                                 Apache is already installed (Apache/2.4.58 (Ubuntu))
[ SKIP ] Tune PHP settings for GLPI                     dependency failed: Install PHP 8.2 and extensions

Succeeded: 8  Failed: 1  Skipped: 4
```

Como a verificação inicial detecta o que já está pronto, o script pode ser executado quantas
vezes for necessário: corrija o motivo da falha, rode de novo e as etapas já concluídas
aparecem no plano como `skip`.

## Repositório de PHP por distribuição

A versão de PHP pedida (padrão `8.2`) muitas vezes não está nos repositórios oficiais da
distro. O script identifica sozinho qual repositório usar:

| Sistema detectado | Repositório usado |
|---|---|
| Ubuntu e derivados (`ID_LIKE=ubuntu`) | PPA `ondrej/php` |
| Debian e derivados (`ID_LIKE=debian`) | Sury (`packages.sury.org/php`) |
| Outras distros baseadas em APT | Apenas os repositórios da própria distro |

Observações:

- Se o repositório já estiver configurado, o script apenas o reutiliza, sem perguntar nem
  adicionar de novo. Linhas comentadas e arquivos desativados (por exemplo
  `.list.disabled`) não contam como configurados.
- No Debian, o repositório Sury é adicionado com a chave em
  `/usr/share/keyrings/sury-php.gpg` e `signed-by` no arquivo
  `/etc/apt/sources.list.d/sury-php.list`, usando o codename detectado do sistema.
- Se você recusar a adição do repositório e a versão de PHP não existir nos repositórios da
  distro, apenas a etapa de PHP falha e é reportada no relatório final; as outras etapas do
  plano continuam sendo executadas.

## Requisitos

- Distribuição Linux baseada em APT (Debian/Ubuntu)
- Acesso root
- Conexão com a internet (download de pacotes e do GLPI a partir do GitHub Releases)

## Uso

Execução direta, sem clonar o repositório:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Peterfilho/glpi-installer/refs/heads/master/glpi-installer.sh)"
```

Ou baixando o script primeiro, o que permite revisar o conteúdo antes de executar:

```bash
curl -fsSLO https://raw.githubusercontent.com/Peterfilho/glpi-installer/refs/heads/master/glpi-installer.sh
sudo bash glpi-installer.sh
```

O script é interativo: pressione Enter para aceitar cada valor padrão sugerido ou informe um
valor customizado. Antes de qualquer alteração no sistema, ele mostra o que já está instalado
e o plano de etapas, que pode ser aceito por inteiro ou ajustado etapa por etapa.

> **Atenção:** não use `curl ... | sudo bash`. Nesse formato o `stdin` fica ocupado pelo
> download e os prompts do script não conseguem ler as suas respostas.

## Após a instalação

O script deixa o servidor (Apache, PHP, MariaDB e os arquivos do GLPI) pronto, mas a
instalação do GLPI em si só é concluída pelo assistente web. Siga estes passos:

1. **Acesse a URL** informada ao final da execução (ou `http://IP_DO_SERVIDOR` caso não
   tenha configurado um `ServerName`).
2. **Conclua o assistente web do GLPI**: idioma, aceite da licença, verificação de
   requisitos e, na etapa de banco de dados, use os dados exibidos ao final da execução
   (ou salvos em `/root/glpi-install-credentials.txt`).
3. Ao final do assistente, o GLPI cria os usuários padrão `glpi/glpi`, `tech/tech`,
   `normal/normal` e `post-only/postonly`. Faça login e troque as senhas (ou desative
   os que não forem usados).
4. **Somente depois de concluir o assistente**, remova o diretório `install/`
   (o GLPI não funciona normalmente enquanto ele existir):
   ```bash
   rm -rf /var/www/glpi/install
   ```
5. Defina uma senha forte para o usuário root do MariaDB, caso ainda não tenha sido feito:
   ```bash
   sudo mariadb
   ALTER USER 'root'@'localhost' IDENTIFIED BY 'SENHA_FORTE';
   FLUSH PRIVILEGES;
   ```

## Arquivos gerados

| Arquivo | Descrição |
|---|---|
| `/var/log/glpi-install.log` | Log completo da execução do script |
| `/root/glpi-install-credentials.txt` | Credenciais do banco de dados e informações da instalação (permissão `600`) |
| `/etc/apache2/sites-available/glpi.conf` | VirtualHost do Apache criado para o GLPI |

## Aviso

Este script realiza alterações no sistema (instalação de pacotes, criação de bancos de dados, configuração do Apache e PHP). Revise o conteúdo antes de executar em ambientes de produção.

## Contribuindo

PRs são bem-vindas! Sinta-se à vontade para abrir uma issue ou enviar um pull request com melhorias, correções ou suporte a novas distribuições.

## Licença

Este projeto está licenciado sob a [Licença MIT](LICENSE).
