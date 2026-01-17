# Move DNS-related files
mv BIND-setup-openSUSE-15.6-EN-with-serial.md dns/
mv BIND-setup-openSUSE-15.6-EN-with-serial-bckp.md dns/

# Move clustering files
mv openSUSE-HA-Cluster-Setup.md clustering/

# Move storage files
mv iscsi_cluster_setup_doc.md storage/

# Move kubernetes files
mv k8s-storage-guide.md kubernetes/

# Move networking files
mv Cloned-VM-Network-Interface-Guide.md networking/

# The bash.sh script - you can either:
# Option 1: Keep it in root if it's a general utility
# Option 2: Move to scripts/ if it's related to a specific topic
mv bash.sh scripts/

# Now commit the changes
git add .
git commit -m "Reorganize documentation into topic-based directories"
git push
