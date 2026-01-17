# Create directory structure
mkdir -p guides/dns
mkdir -p guides/clustering
mkdir -p guides/storage
mkdir -p scripts

# Add .gitkeep files
touch guides/dns/.gitkeep
touch guides/clustering/.gitkeep
touch guides/storage/.gitkeep
touch scripts/.gitkeep

# Commit all at once
git add .
git commit -m "Add directory structure for future guides"
git push
