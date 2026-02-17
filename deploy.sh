#!/bin/bash
set -e

# Hub Chat Deployment Script
# Deploys white-labeled Open WebUI to Google Cloud Run

# Configuration
PROJECT_ID="hub-chat-prod"
REGION="us-central1"
SERVICE_NAME="openwebui"
REGISTRY="us-central1-docker.pkg.dev/${PROJECT_ID}/containers/open-webui"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get version info
BUILD_HASH=$(git rev-parse --short HEAD)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DEFAULT_TAG="hub-chat-${BUILD_HASH}"

# Parse arguments
TAG="${1:-$DEFAULT_TAG}"
SKIP_BUILD=false
DRY_RUN=false
NO_CACHE=false

usage() {
    echo "Usage: $0 [TAG] [OPTIONS]"
    echo ""
    echo "Arguments:"
    echo "  TAG           Docker image tag (default: hub-chat-<git-hash>)"
    echo ""
    echo "Options:"
    echo "  --no-cache    Force rebuild without Docker cache (use after updating assets)"
    echo "  --skip-build  Skip Docker build, only deploy existing image"
    echo "  --dry-run     Show what would be done without executing"
    echo "  --help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                      # Build and deploy with auto-generated tag"
    echo "  $0 v1.0.0               # Build and deploy with tag 'v1.0.0'"
    echo "  $0 --no-cache           # Rebuild without cache (for asset updates)"
    echo "  $0 v1.0.0 --skip-build  # Deploy existing image tagged 'v1.0.0'"
    exit 0
}

# Parse options
for arg in "$@"; do
    case $arg in
        --skip-build)
            SKIP_BUILD=true
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --no-cache)
            NO_CACHE=true
            ;;
        --help|-h)
            usage
            ;;
    esac
done

# Remove flags from TAG if it's a flag
if [[ "$TAG" == --* ]]; then
    TAG="$DEFAULT_TAG"
fi

IMAGE="${REGISTRY}:${TAG}"

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}  Hub Chat Deployment${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo -e "Project:    ${YELLOW}${PROJECT_ID}${NC}"
echo -e "Region:     ${YELLOW}${REGION}${NC}"
echo -e "Service:    ${YELLOW}${SERVICE_NAME}${NC}"
echo -e "Image:      ${YELLOW}${IMAGE}${NC}"
echo -e "Git Hash:   ${YELLOW}${BUILD_HASH}${NC}"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY RUN] Would execute the following:${NC}"
    echo ""
fi

# Check prerequisites
echo -e "${GREEN}[1/4] Checking prerequisites...${NC}"

if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: docker is not installed${NC}"
    exit 1
fi

if ! command -v gcloud &> /dev/null; then
    echo -e "${RED}Error: gcloud CLI is not installed${NC}"
    exit 1
fi

# Check gcloud authentication
if ! gcloud auth print-identity-token &> /dev/null; then
    echo -e "${RED}Error: Not authenticated with gcloud. Run 'gcloud auth login'${NC}"
    exit 1
fi

# Check Docker authentication for Artifact Registry
if ! docker-credential-gcloud list 2>/dev/null | grep -q "us-central1-docker.pkg.dev"; then
    echo -e "${YELLOW}Configuring Docker for Artifact Registry...${NC}"
    if [ "$DRY_RUN" = false ]; then
        gcloud auth configure-docker us-central1-docker.pkg.dev --quiet
    else
        echo "  gcloud auth configure-docker us-central1-docker.pkg.dev --quiet"
    fi
fi

echo -e "${GREEN}✓ Prerequisites OK${NC}"
echo ""

# Build Docker image
if [ "$SKIP_BUILD" = false ]; then
    echo -e "${GREEN}[2/4] Building Docker image for linux/amd64...${NC}"
    echo -e "      This may take 5-10 minutes..."

    CACHE_FLAG=""
    if [ "$NO_CACHE" = true ]; then
        CACHE_FLAG="--no-cache"
        echo -e "      ${YELLOW}(--no-cache enabled, full rebuild)${NC}"
    fi

    if [ "$DRY_RUN" = false ]; then
        docker buildx build \
            --platform=linux/amd64 \
            --build-arg="USE_SLIM=true" \
            --build-arg="BUILD_HASH=${BUILD_HASH}" \
            ${CACHE_FLAG} \
            -t "${IMAGE}" \
            --push \
            .
    else
        echo "  docker buildx build --platform=linux/amd64 --build-arg=\"USE_SLIM=true\" --build-arg=\"BUILD_HASH=${BUILD_HASH}\" ${CACHE_FLAG} -t \"${IMAGE}\" --push ."
    fi

    echo -e "${GREEN}✓ Image built and pushed${NC}"
else
    echo -e "${YELLOW}[2/4] Skipping build (--skip-build)${NC}"

    # Verify image exists
    if [ "$DRY_RUN" = false ]; then
        if ! gcloud artifacts docker images describe "${IMAGE}" --project="${PROJECT_ID}" &> /dev/null; then
            echo -e "${RED}Error: Image ${IMAGE} does not exist in registry${NC}"
            exit 1
        fi
        echo -e "${GREEN}✓ Image exists in registry${NC}"
    fi
fi
echo ""

# Deploy to Cloud Run
echo -e "${GREEN}[3/4] Deploying to Cloud Run...${NC}"

if [ "$DRY_RUN" = false ]; then
    gcloud run deploy "${SERVICE_NAME}" \
        --image="${IMAGE}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}"
else
    echo "  gcloud run deploy \"${SERVICE_NAME}\" --image=\"${IMAGE}\" --region=\"${REGION}\" --project=\"${PROJECT_ID}\""
fi

echo -e "${GREEN}✓ Deployed to Cloud Run${NC}"
echo ""

# Verify deployment
echo -e "${GREEN}[4/4] Verifying deployment...${NC}"

if [ "$DRY_RUN" = false ]; then
    # Get service URL
    SERVICE_URL=$(gcloud run services describe "${SERVICE_NAME}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --format="value(status.url)")

    # Check if service is responding
    if curl -s -o /dev/null -w "%{http_code}" "${SERVICE_URL}" | grep -q "200\|302"; then
        echo -e "${GREEN}✓ Service is responding${NC}"
    else
        echo -e "${YELLOW}⚠ Service may still be starting up${NC}"
    fi

    echo ""
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  Deployment Complete!${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    echo -e "Service URL:  ${YELLOW}${SERVICE_URL}${NC}"
    echo -e "Custom URL:   ${YELLOW}https://chat.hub.inc${NC}"
    echo -e "Image:        ${YELLOW}${IMAGE}${NC}"
    echo ""
else
    echo ""
    echo -e "${YELLOW}[DRY RUN] No changes were made${NC}"
fi
