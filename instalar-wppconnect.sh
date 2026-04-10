#!/bin/bash

# ============================================================
#   INSTALADOR WPPConnect Server - Ubuntu VPS
#   Autor: KTech Eletrônicos
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()   { echo -e "${YELLOW}[AVISO]${NC} $1"; }
error()  { echo -e "${RED}[ERRO]${NC} $1"; exit 1; }
info()   { echo -e "${CYAN}[INFO]${NC} $1"; }
header() { echo -e "\n${BOLD}${CYAN}==> $1${NC}"; }

# ============================================================
# CONFIGURAÇÕES — EDITE ANTES DE RODAR SE QUISER
# ============================================================
INSTALL_DIR="/opt/wppconnect-server"
SERVICE_USER="wppconnect"
NODE_VERSION="20"
APP_PORT="21465"
SECRET_KEY="Senha@secreta123"  # <-- Altere para sua senha

# ============================================================
# VERIFICAÇÕES INICIAIS
# ============================================================
header "Verificando ambiente"

[ "$EUID" -ne 0 ] && error "Execute como root: sudo bash instalar-wppconnect.sh"

OS=$(lsb_release -si 2>/dev/null || echo "Unknown")
[[ "$OS" != "Ubuntu" && "$OS" != "Debian" ]] && warn "Sistema não é Ubuntu/Debian. Pode haver incompatibilidades."

log "Sistema: $(lsb_release -sd 2>/dev/null || uname -a)"
log "Usuário: $(whoami)"

# ============================================================
# ATUALIZAR SISTEMA
# ============================================================
header "Atualizando sistema"
apt-get update -qq
apt-get upgrade -y -qq
log "Sistema atualizado"

# ============================================================
# INSTALAR NODE.JS via NVM
# ============================================================
header "Instalando Node.js $NODE_VERSION"

if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - > /dev/null 2>&1
    apt-get install -y nodejs > /dev/null 2>&1
    log "Node.js $(node -v) instalado"
else
    log "Node.js já instalado: $(node -v)"
fi

# ============================================================
# INSTALAR YARN
# ============================================================
header "Instalando Yarn"
if ! command -v yarn &>/dev/null; then
    npm install -g yarn > /dev/null 2>&1
    log "Yarn $(yarn -v) instalado"
else
    log "Yarn já instalado: $(yarn -v)"
fi

# ============================================================
# INSTALAR GIT
# ============================================================
header "Instalando Git"
if ! command -v git &>/dev/null; then
    apt-get install -y git > /dev/null 2>&1
fi
log "Git $(git --version) disponível"

# ============================================================
# DEPENDÊNCIAS DO PUPPETEER
# ============================================================
header "Instalando dependências do Puppeteer"
apt-get install -y \
    libxshmfence-dev libgbm-dev wget unzip fontconfig locales \
    gconf-service libasound2 libatk1.0-0 libc6 libcairo2 libcups2 \
    libdbus-1-3 libexpat1 libfontconfig1 libgcc1 libgconf-2-4 \
    libgdk-pixbuf2.0-0 libglib2.0-0 libgtk-3-0 libnspr4 \
    libpango-1.0-0 libpangocairo-1.0-0 libstdc++6 libx11-6 \
    libx11-xcb1 libxcb1 libxcomposite1 libxcursor1 libxdamage1 \
    libxext6 libxfixes3 libxi6 libxrandr2 libxrender1 libxss1 \
    libxtst6 ca-certificates fonts-liberation libappindicator1 \
    libnss3 lsb-release xdg-utils libvips-dev > /dev/null 2>&1
log "Dependências do Puppeteer instaladas"

# ============================================================
# INSTALAR GOOGLE CHROME
# ============================================================
header "Instalando Google Chrome"
if ! command -v google-chrome &>/dev/null && ! command -v google-chrome-stable &>/dev/null; then
    cd /tmp
    wget -q -c https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    apt-get install -y libappindicator1 > /dev/null 2>&1 || true
    dpkg -i google-chrome-stable_current_amd64.deb > /dev/null 2>&1 || true
    apt-get install -f -y > /dev/null 2>&1
    rm -f google-chrome-stable_current_amd64.deb
    log "Google Chrome instalado: $(google-chrome --version 2>/dev/null || echo 'OK')"
else
    log "Google Chrome já instalado"
fi

# ============================================================
# CRIAR USUÁRIO DE SERVIÇO
# ============================================================
header "Criando usuário de serviço '$SERVICE_USER'"
if ! id "$SERVICE_USER" &>/dev/null; then
    useradd -r -m -d /home/$SERVICE_USER -s /bin/bash $SERVICE_USER
    log "Usuário '$SERVICE_USER' criado"
else
    log "Usuário '$SERVICE_USER' já existe"
fi

# ============================================================
# CLONAR REPOSITÓRIO
# ============================================================
header "Clonando WPPConnect Server"
if [ -d "$INSTALL_DIR" ]; then
    warn "Diretório $INSTALL_DIR já existe. Fazendo backup..."
    mv "$INSTALL_DIR" "${INSTALL_DIR}.bak.$(date +%Y%m%d%H%M%S)"
fi

git clone https://github.com/wppconnect-team/wppconnect-server.git "$INSTALL_DIR" > /dev/null 2>&1
log "Repositório clonado em $INSTALL_DIR"

# ============================================================
# INSTALAR DEPENDÊNCIAS DO PROJETO
# ============================================================
header "Instalando dependências npm/yarn"
cd "$INSTALL_DIR"

yarn install > /dev/null 2>&1 || npm install > /dev/null 2>&1
log "Dependências instaladas"

# Corrigir sharp se necessário
yarn add sharp --ignore-engines > /dev/null 2>&1 || true
log "Sharp configurado"

# ============================================================
# BUILD DO PROJETO
# ============================================================
header "Fazendo build do projeto"
cd "$INSTALL_DIR"
yarn build > /dev/null 2>&1
log "Build concluído"

# ============================================================
# CONFIGURAR ARQUIVO DE CONFIGURAÇÃO
# ============================================================
header "Configurando wppconnect"
CONFIG_FILE="$INSTALL_DIR/src/config.ts"
DIST_CONFIG="$INSTALL_DIR/dist/config.js"

# Ajustar porta e secret no arquivo de config principal se existir
if [ -f "$CONFIG_FILE" ]; then
    sed -i "s/port: [0-9]*/port: $APP_PORT/" "$CONFIG_FILE" 2>/dev/null || true
    sed -i "s/secretKey: '.*'/secretKey: '$SECRET_KEY'/" "$CONFIG_FILE" 2>/dev/null || true
    log "config.ts ajustado (porta $APP_PORT)"
fi

# ============================================================
# CONFIGURAR PERMISSÕES
# ============================================================
header "Configurando permissões"
chown -R $SERVICE_USER:$SERVICE_USER "$INSTALL_DIR"
chmod -R 755 "$INSTALL_DIR"
log "Permissões configuradas"

# ============================================================
# CRIAR SERVIÇO SYSTEMD
# ============================================================
header "Criando serviço systemd"

cat > /etc/systemd/system/wppconnect.service << EOF
[Unit]
Description=WPPConnect Server
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$(which yarn) start
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=wppconnect

# Variáveis de ambiente
Environment=NODE_ENV=production
Environment=PORT=$APP_PORT

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wppconnect
systemctl start wppconnect
log "Serviço wppconnect criado e iniciado"

# ============================================================
# VERIFICAR SE SUBIU
# ============================================================
header "Verificando status do serviço"
sleep 5

if systemctl is-active --quiet wppconnect; then
    log "WPPConnect está RODANDO"
else
    warn "Serviço pode estar inicializando ainda. Verifique com: journalctl -u wppconnect -f"
fi

# ============================================================
# INSTALAR PM2 COMO ALTERNATIVA (OPCIONAL)
# ============================================================
header "Instalando PM2 como gerenciador alternativo"
npm install -g pm2 > /dev/null 2>&1
log "PM2 instalado (alternativa ao systemd)"

# ============================================================
# RESUMO FINAL
# ============================================================
IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo -e "${BOLD}${GREEN}   INSTALAÇÃO CONCLUÍDA COM SUCESSO!${NC}"
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo ""
echo -e "${BOLD}📡 Acesso ao servidor:${NC}"
echo -e "   URL:        http://${IP}:${APP_PORT}"
echo -e "   Secret Key: ${SECRET_KEY}"
echo ""
echo -e "${BOLD}⚙️  Configurações:${NC}"
echo -e "   Arquivo:    ${INSTALL_DIR}/src/config.ts"
echo -e "   Após editar, rode: sudo bash /opt/wppconnect-server/aplicar-config.sh"
echo ""
echo -e "${BOLD}🔧 Comandos úteis:${NC}"
echo -e "   Status:     sudo systemctl status wppconnect"
echo -e "   Logs ao vivo: sudo journalctl -u wppconnect -f"
echo -e "   Reiniciar:  sudo systemctl restart wppconnect"
echo -e "   Parar:      sudo systemctl stop wppconnect"
echo ""
echo -e "${BOLD}📄 Próximos passos:${NC}"
echo -e "   1. Edite as configurações em: ${INSTALL_DIR}/src/config.ts"
echo -e "   2. Rode o script de reaplicação: sudo bash /opt/wppconnect-server/aplicar-config.sh"
echo -e "   3. Acesse http://${IP}:${APP_PORT} para verificar o servidor"
echo ""

# ============================================================
# CRIAR SCRIPT DE REAPLICAÇÃO DE CONFIG
# ============================================================
cat > "$INSTALL_DIR/aplicar-config.sh" << 'REAPPLY'
#!/bin/bash
echo "🔄 Rebuilding WPPConnect Server..."
cd /opt/wppconnect-server
yarn build
echo "✅ Build concluído. Reiniciando serviço..."
systemctl restart wppconnect
sleep 3
systemctl status wppconnect --no-pager
echo ""
echo "✅ Pronto! Configurações aplicadas."
REAPPLY

chmod +x "$INSTALL_DIR/aplicar-config.sh"
chown $SERVICE_USER:$SERVICE_USER "$INSTALL_DIR/aplicar-config.sh"
log "Script aplicar-config.sh criado em $INSTALL_DIR"
