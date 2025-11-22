# Deployment Guide

This guide covers deploying Itinera to production.

## Prerequisites

- PostgreSQL database
- Redis instance
- API keys:
  - OpenAI API key
  - Google Maps API key
  - TikTok API credentials (optional, uses mock data by default)

## Option 1: Docker Deployment (Recommended)

### 1. Create Docker Compose Configuration

Create `docker-compose.yml` in the project root:

```yaml
version: '3.8'

services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_DB: itinera
      POSTGRES_USER: itinera
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"

  backend:
    build:
      context: ./backend
      dockerfile: Dockerfile
    environment:
      DATABASE_URL: postgresql://itinera:${POSTGRES_PASSWORD}@postgres:5432/itinera
      REDIS_URL: redis://redis:6379/0
      OPENAI_API_KEY: ${OPENAI_API_KEY}
      GOOGLE_MAPS_API_KEY: ${GOOGLE_MAPS_API_KEY}
      TIKTOK_API_KEY: ${TIKTOK_API_KEY}
    depends_on:
      - postgres
      - redis
    ports:
      - "8000:8000"
    command: uvicorn app.main:app --host 0.0.0.0 --port 8000

  worker:
    build:
      context: ./backend
      dockerfile: Dockerfile
    environment:
      DATABASE_URL: postgresql://itinera:${POSTGRES_PASSWORD}@postgres:5432/itinera
      REDIS_URL: redis://redis:6379/0
      OPENAI_API_KEY: ${OPENAI_API_KEY}
      GOOGLE_MAPS_API_KEY: ${GOOGLE_MAPS_API_KEY}
      TIKTOK_API_KEY: ${TIKTOK_API_KEY}
    depends_on:
      - postgres
      - redis
    command: celery -A app.workers.celery_app worker --loglevel=info

  frontend:
    build:
      context: ./frontend
      dockerfile: Dockerfile
    environment:
      REACT_APP_API_URL: http://backend:8000
      REACT_APP_GOOGLE_MAPS_API_KEY: ${GOOGLE_MAPS_API_KEY}
    ports:
      - "3000:80"
    depends_on:
      - backend

volumes:
  postgres_data:
```

### 2. Create Backend Dockerfile

Create `backend/Dockerfile`:

```dockerfile
FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Run migrations on startup
CMD ["sh", "-c", "alembic upgrade head && uvicorn app.main:app --host 0.0.0.0 --port 8000"]
```

### 3. Create Frontend Dockerfile

Create `frontend/Dockerfile`:

```dockerfile
FROM node:18-alpine as build

WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY . .
RUN npm run build

FROM nginx:alpine
COPY --from=build /app/build /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

Create `frontend/nginx.conf`:

```nginx
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location /api {
        proxy_pass http://backend:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

### 4. Deploy

```bash
# Set environment variables
export POSTGRES_PASSWORD=your_secure_password
export OPENAI_API_KEY=your_openai_key
export GOOGLE_MAPS_API_KEY=your_google_maps_key
export TIKTOK_API_KEY=your_tiktok_key

# Build and start
docker-compose up -d

# View logs
docker-compose logs -f

# Stop
docker-compose down
```

## Option 2: Platform-as-a-Service (Heroku, Railway, Render)

### Railway.app Example

1. **Create a new project** on Railway

2. **Add PostgreSQL and Redis** from the marketplace

3. **Deploy Backend:**
   - Connect your GitHub repo
   - Set root directory: `backend`
   - Add environment variables
   - Start command: `uvicorn app.main:app --host 0.0.0.0 --port $PORT`

4. **Deploy Worker:**
   - Add a new service from same repo
   - Set root directory: `backend`
   - Start command: `celery -A app.workers.celery_app worker --loglevel=info`

5. **Deploy Frontend:**
   - Add a new service from same repo
   - Set root directory: `frontend`
   - Build command: `npm run build`
   - Start command: `npx serve -s build -p $PORT`

### Environment Variables

Backend and Worker need:
```
DATABASE_URL=postgresql://...
REDIS_URL=redis://...
OPENAI_API_KEY=sk-...
GOOGLE_MAPS_API_KEY=AIza...
TIKTOK_API_KEY=...
```

Frontend needs:
```
REACT_APP_API_URL=https://your-backend.railway.app
REACT_APP_GOOGLE_MAPS_API_KEY=AIza...
```

## Option 3: Traditional VPS (DigitalOcean, AWS EC2, etc.)

### 1. Provision Server

- Ubuntu 22.04 LTS
- Minimum 2GB RAM
- 2 CPU cores recommended

### 2. Install Dependencies

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install Python
sudo apt install python3.11 python3.11-venv python3-pip -y

# Install Node.js
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install nodejs -y

# Install PostgreSQL
sudo apt install postgresql postgresql-contrib -y

# Install Redis
sudo apt install redis-server -y

# Install Nginx
sudo apt install nginx -y
```

### 3. Set Up Database

```bash
sudo -u postgres psql

CREATE DATABASE itinera;
CREATE USER itinera WITH PASSWORD 'secure_password';
GRANT ALL PRIVILEGES ON DATABASE itinera TO itinera;
\q
```

### 4. Deploy Backend

```bash
# Clone repo
git clone https://github.com/your-username/itinera.git
cd itinera/backend

# Create virtual environment
python3.11 -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Set environment variables
export DATABASE_URL="postgresql://itinera:secure_password@localhost/itinera"
export REDIS_URL="redis://localhost:6379/0"
export OPENAI_API_KEY="your_key"
export GOOGLE_MAPS_API_KEY="your_key"

# Run migrations
alembic upgrade head

# Test run
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

### 5. Set Up Systemd Services

Create `/etc/systemd/system/itinera-api.service`:

```ini
[Unit]
Description=Itinera API
After=network.target

[Service]
Type=notify
User=www-data
WorkingDirectory=/var/www/itinera/backend
Environment="DATABASE_URL=postgresql://..."
Environment="REDIS_URL=redis://localhost:6379/0"
Environment="OPENAI_API_KEY=..."
Environment="GOOGLE_MAPS_API_KEY=..."
ExecStart=/var/www/itinera/backend/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
```

Create `/etc/systemd/system/itinera-worker.service`:

```ini
[Unit]
Description=Itinera Celery Worker
After=network.target redis.service

[Service]
Type=forking
User=www-data
WorkingDirectory=/var/www/itinera/backend
Environment="DATABASE_URL=postgresql://..."
Environment="REDIS_URL=redis://localhost:6379/0"
Environment="OPENAI_API_KEY=..."
Environment="GOOGLE_MAPS_API_KEY=..."
ExecStart=/var/www/itinera/backend/venv/bin/celery -A app.workers.celery_app worker --loglevel=info
Restart=always

[Install]
WantedBy=multi-user.target
```

Enable and start services:

```bash
sudo systemctl enable itinera-api
sudo systemctl enable itinera-worker
sudo systemctl start itinera-api
sudo systemctl start itinera-worker
```

### 6. Deploy Frontend

```bash
cd /var/www/itinera/frontend

# Install dependencies
npm install

# Build
REACT_APP_API_URL=https://your-domain.com npm run build

# Copy to Nginx
sudo cp -r build/* /var/www/html/
```

### 7. Configure Nginx

Create `/etc/nginx/sites-available/itinera`:

```nginx
server {
    listen 80;
    server_name your-domain.com;

    # Frontend
    location / {
        root /var/www/html;
        try_files $uri $uri/ /index.html;
    }

    # Backend API
    location /api {
        proxy_pass http://localhost:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # WebSocket support (future)
    location /ws {
        proxy_pass http://localhost:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

Enable site:

```bash
sudo ln -s /etc/nginx/sites-available/itinera /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

### 8. SSL with Let's Encrypt

```bash
sudo apt install certbot python3-certbot-nginx -y
sudo certbot --nginx -d your-domain.com
```

## Production Checklist

### Security

- [ ] Change all default passwords
- [ ] Use strong, unique API keys
- [ ] Enable HTTPS (SSL certificate)
- [ ] Configure firewall (ufw or security groups)
- [ ] Set up fail2ban for SSH protection
- [ ] Disable debug mode (`DEBUG=False`)
- [ ] Use environment variables for secrets
- [ ] Implement rate limiting
- [ ] Regular security updates

### Performance

- [ ] Enable Nginx gzip compression
- [ ] Set up CDN for static assets
- [ ] Configure PostgreSQL connection pooling
- [ ] Add database indexes
- [ ] Enable Redis persistence (optional)
- [ ] Set up caching headers
- [ ] Optimize Docker images (multi-stage builds)

### Monitoring

- [ ] Set up logging aggregation (e.g., Papertrail)
- [ ] Configure error tracking (e.g., Sentry)
- [ ] Set up uptime monitoring (e.g., UptimeRobot)
- [ ] Monitor database performance
- [ ] Track API response times
- [ ] Set up alerts for failures

### Backup

- [ ] Automated database backups
- [ ] Store backups offsite
- [ ] Test restore procedures
- [ ] Document backup schedule

### Scaling

- [ ] Multiple Celery workers
- [ ] Load balancer (for multiple API instances)
- [ ] Database read replicas
- [ ] Redis cluster (for high availability)
- [ ] Horizontal pod autoscaling (Kubernetes)

## Maintenance

### Update Application

```bash
# Pull latest code
git pull origin main

# Backend
cd backend
source venv/bin/activate
pip install -r requirements.txt
alembic upgrade head
sudo systemctl restart itinera-api
sudo systemctl restart itinera-worker

# Frontend
cd ../frontend
npm install
npm run build
sudo cp -r build/* /var/www/html/
```

### View Logs

```bash
# API logs
sudo journalctl -u itinera-api -f

# Worker logs
sudo journalctl -u itinera-worker -f

# Nginx logs
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/log/nginx/error.log
```

### Database Migrations

```bash
cd backend
source venv/bin/activate

# Create migration
alembic revision --autogenerate -m "Description"

# Apply migration
alembic upgrade head

# Rollback
alembic downgrade -1
```

## Troubleshooting

### Backend won't start

- Check logs: `journalctl -u itinera-api -n 50`
- Verify database connection
- Check environment variables
- Ensure migrations are applied

### Worker not processing jobs

- Check Redis is running: `redis-cli ping`
- View worker logs: `journalctl -u itinera-worker -n 50`
- Check Celery is running: `celery -A app.workers.celery_app inspect active`

### Frontend not loading

- Check Nginx configuration: `nginx -t`
- Verify API URL in environment variables
- Check browser console for errors
- Ensure backend is accessible

## Support

For issues and questions:
- GitHub Issues: https://github.com/your-username/itinera/issues
- Documentation: See README.md and ARCHITECTURE.md

