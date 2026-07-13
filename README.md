# GLPI Installer

Script Bash para automatizar a instalação do [GLPI](https://glpi-project.org/) em servidores Debian/Ubuntu (baseados em APT), com Apache, PHP e MariaDB.

## O que o script faz

1. **Detecta o sistema operacional** a partir de `/etc/os-release` e valida que é uma distro baseada em APT.
2. **Coleta as configurações da instalação** interativamente, com valores padrão sugeridos:
   - Versão do GLPI (padrão: `11.0.8`)
   - Versão do PHP (padrão: `8.2`)
   - Nome do banco de dados e usuário do GLPI
   - Senha do banco (gera uma senha aleatória com `openssl rand -hex 18`, ou permite informar uma)
   - Caminho de instalação (padrão: `/var/www/glpi`)
   - `ServerName` do Apache (opcional)
   - Aplicação de hardening básico no MariaDB (equivalente ao `mysql_secure_installation`)
   - Uso do PPA `ondrej/php` no Ubuntu, para instalar a versão de PHP desejada
3. **Exibe um resumo** e pede confirmação antes de prosseguir.
4. **Atualiza o sistema** e instala pacotes base (`curl`, `wget`, `unzip`, `gnupg`, etc.).
5. **Configura o repositório de PHP** (PPA `ondrej/php`, se selecionado).
6. **Instala a stack web**: Apache, MariaDB e PHP com todas as extensões exigidas pelo GLPI (`curl`, `gd`, `mbstring`, `mysql`, `xml`, `imap`, `ldap`, `soap`, `snmp`, `apcu`, `intl`, `bz2`, `zip`, `bcmath`).
7. **Aplica hardening básico no MariaDB** (remove usuários anônimos e o banco `test`), se confirmado.
8. **Cria o banco de dados e o usuário do GLPI**, com as credenciais informadas, e testa a autenticação.
9. **Baixa e extrai o GLPI** da versão especificada diretamente do GitHub Releases, fazendo backup automático de uma instalação existente no mesmo caminho.
10. **Configura o VirtualHost do Apache**, com `mod_rewrite` habilitado e regras para repassar o cabeçalho `Authorization` e redirecionar requisições para `index.php`.
11. **Ajusta o `php.ini`** (`memory_limit`, `upload_max_filesize`, `post_max_size`, `max_execution_time`, `session.cookie_httponly`, `expose_php`).
12. **Configura as permissões** do diretório de instalação (`www-data`, com `775` em `files`, `config`, `plugins` e `marketplace`).
13. **Salva as credenciais** geradas em `/root/glpi-install-credentials.txt` (permissão `600`).
14. **Exibe um passo a passo final**, explicando que o GLPI ainda não está instalado (isso só acontece pelo assistente web) e o que fazer em seguida.

Todo o processo é registrado em `/var/log/glpi-install.log`.

> **Importante:** o script **não** remove o diretório `install/` do GLPI. Essa remoção só pode
> acontecer depois de concluir o assistente de instalação pelo navegador — removê-lo antes
> impede o GLPI de configurar idioma, licença e conexão com o banco pela interface web.

## Requisitos

- Distribuição Linux baseada em APT (Debian/Ubuntu)
- Acesso root
- Conexão com a internet (download de pacotes e do GLPI a partir do GitHub Releases)

## Uso

```bash
sudo bash glpi-installer.sh
```

O script é interativo: pressione Enter para aceitar cada valor padrão sugerido ou informe um valor customizado.

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
