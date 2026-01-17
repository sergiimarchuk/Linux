# Create the directory structure
mkdir -p dns clustering storage kubernetes monitoring networking tips

# Move existing files (example)
git mv BIND-setup-opensuse-15.6-EN-with-serial.md dns/
git mv High-Availability-Cluster-PacemakerO-Suse.md clustering/
git mv ISCSI-cluster-setup.md storage/
git mv k8s-install-guide.md kubernetes/
git mv CPU-Temperature-Fan-Monitoring-Linux.md monitoring/
git mv OpenSuse-Network-Config.md networking/
git mv Linux-Tips.md tips/

# Add .gitkeep to empty subdirectories if needed
touch dns/scripts/.gitkeep
touch kubernetes/manifests/.gitkeep

# Commit
git add .
git commit -m "Reorganize repository structure by topic"
git push
