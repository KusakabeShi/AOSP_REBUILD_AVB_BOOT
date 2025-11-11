#!/usr/bin/env python3
import os
import subprocess
import sys
import shutil
import re
import argparse
from datetime import datetime
import sys
PYTHON_EXECUTABLE = sys.executable or "python3"


class AvbImageParser:
    """AVB image information parser class"""
    
    @staticmethod
    def run_command(cmd, description="", capture_output=True):
        """Execute command and return result"""
        if description:
            print(f"[INFO] {description}")
        print(f"[CMD] {' '.join(cmd)}")
        
        try:
            result = subprocess.run(cmd, capture_output=capture_output, text=True, check=True)
            if result.stdout and capture_output:
                print(f"[OUTPUT]\n{result.stdout}")
            return result
        except subprocess.CalledProcessError as e:
            print(f"[ERROR] Command execution failed: {e}")
            if e.stderr:
                print(f"[ERROR] Error output: {e.stderr}")
            return None

    @staticmethod
    def parse_image_info(avbtool_path, image_path):
        """Parse image information and return structured data"""
        cmd = [PYTHON_EXECUTABLE, avbtool_path, "info_image", "--image", image_path]
        result = AvbImageParser.run_command(cmd, f"Parsing {image_path} information")
        
        if not result or not result.stdout:
            return None
        
        output = result.stdout
        info = {}
        
        info['algorithm'] = AvbImageParser._extract_pattern(output, r'Algorithm:\s+(\S+)')
        info['rollback_index'] = AvbImageParser._extract_pattern(output, r'Rollback Index:\s+(\d+)')
        info['flags'] = AvbImageParser._extract_pattern(output, r'Flags:\s+(\d+)')
        
        info['image_size'] = AvbImageParser._extract_pattern(output, r'Image size:\s+(\d+) bytes')
        info['original_image_size'] = AvbImageParser._extract_pattern(output, r'Original image size:\s+(\d+) bytes')
        
        info['descriptors'] = AvbImageParser._parse_descriptors(output)
        
        return info
    
    @staticmethod
    def _extract_pattern(text, pattern):
        """Extract matching pattern"""
        match = re.search(pattern, text)
        return match.group(1) if match else None
    
    @staticmethod
    def _parse_descriptors(output):
        """Parse descriptor information"""
        descriptors = []
        
        descriptor_blocks = re.split(r'    (Hash descriptor|Hashtree descriptor|Chain Partition descriptor|Prop):', output)
        
        for i in range(1, len(descriptor_blocks), 2):
            desc_type = descriptor_blocks[i].strip()
            desc_content = descriptor_blocks[i+1] if i+1 < len(descriptor_blocks) else ""
            
            if desc_type == "Hash descriptor":
                descriptor = AvbImageParser._parse_hash_descriptor(desc_content)
                descriptor['type'] = 'hash'
                descriptors.append(descriptor)
            elif desc_type == "Hashtree descriptor":
                descriptor = AvbImageParser._parse_hashtree_descriptor(desc_content)
                descriptor['type'] = 'hashtree'
                descriptors.append(descriptor)
            elif desc_type == "Chain Partition descriptor":
                descriptor = AvbImageParser._parse_chain_descriptor(desc_content)
                descriptor['type'] = 'chain'
                descriptors.append(descriptor)
            elif desc_type == "Prop":
                descriptor = AvbImageParser._parse_prop_descriptor(desc_content)
                descriptor['type'] = 'prop'
                descriptors.append(descriptor)
        
        return descriptors
    
    @staticmethod
    def _parse_hash_descriptor(content):
        """Parse Hash descriptor"""
        return {
            'image_size': AvbImageParser._extract_pattern(content, r'Image Size:\s+(\d+) bytes'),
            'hash_algorithm': AvbImageParser._extract_pattern(content, r'Hash Algorithm:\s+(\S+)'),
            'partition_name': AvbImageParser._extract_pattern(content, r'Partition Name:\s+(\S+)'),
            'salt': AvbImageParser._extract_pattern(content, r'Salt:\s+([a-fA-F0-9]+)'),
            'digest': AvbImageParser._extract_pattern(content, r'Digest:\s+([a-fA-F0-9]+)'),
            'flags': AvbImageParser._extract_pattern(content, r'Flags:\s+(\d+)')
        }
    
    @staticmethod
    def _parse_hashtree_descriptor(content):
        """Parse Hashtree descriptor"""
        return {
            'image_size': AvbImageParser._extract_pattern(content, r'Image Size:\s+(\d+) bytes'),
            'hash_algorithm': AvbImageParser._extract_pattern(content, r'Hash Algorithm:\s+(\S+)'),
            'partition_name': AvbImageParser._extract_pattern(content, r'Partition Name:\s+(\S+)'),
            'salt': AvbImageParser._extract_pattern(content, r'Salt:\s+([a-fA-F0-9]+)'),
            'root_digest': AvbImageParser._extract_pattern(content, r'Root Digest:\s+([a-fA-F0-9]+)'),
            'flags': AvbImageParser._extract_pattern(content, r'Flags:\s+(\d+)'),
            'tree_offset': AvbImageParser._extract_pattern(content, r'Tree Offset:\s+(\d+)'),
            'tree_size': AvbImageParser._extract_pattern(content, r'Tree Size:\s+(\d+) bytes'),
            'data_block_size': AvbImageParser._extract_pattern(content, r'Data Block Size:\s+(\d+) bytes'),
            'hash_block_size': AvbImageParser._extract_pattern(content, r'Hash Block Size:\s+(\d+) bytes')
        }
    
    @staticmethod
    def _parse_chain_descriptor(content):
        """Parse Chain descriptor"""
        return {
            'partition_name': AvbImageParser._extract_pattern(content, r'Partition Name:\s+(\S+)'),
            'rollback_index_location': AvbImageParser._extract_pattern(content, r'Rollback Index Location:\s+(\d+)'),
            'public_key_sha1': AvbImageParser._extract_pattern(content, r'Public key \(sha1\):\s+([a-fA-F0-9]+)'),
            'flags': AvbImageParser._extract_pattern(content, r'Flags:\s+(\d+)')
        }
    
    @staticmethod
    def _parse_prop_descriptor(content):
        """Parse property descriptor"""
        # Property format: key -> 'value'
        prop_match = re.search(r"(\S+)\s+->\s+'([^']*)'", content)
        if prop_match:
            return {
                'key': prop_match.group(1),
                'value': prop_match.group(2)
            }
        return {}

class AvbRebuilder:
    """AVB Rebuilder class"""
    
    def __init__(self, working_dir=None, avbtool_path=None, private_key=None):
        self.working_dir = working_dir or os.getcwd()
        self.avbtool_path = avbtool_path or os.path.join(self.working_dir, "tools", "avbtool.py")
        self.parser = AvbImageParser()
        
        os.chdir(self.working_dir)
        print(f"Current working directory: {os.getcwd()}")
        
        if private_key:
            # If relative path, convert to absolute path and normalize path separators
            if not os.path.isabs(private_key):
                self.private_key = os.path.normpath(os.path.join(self.working_dir, private_key))
            else:
                self.private_key = os.path.normpath(private_key)
            self.available_keys = [self.private_key]  
            print(f"[INFO] Using manually specified private key: {self.private_key}")
        else:
            self.available_keys = self.auto_detect_private_key()
            self.private_key = None 
    
    def auto_detect_private_key(self):
        """Auto-detect available private key files"""
        key_candidates = [
            "tools/pem/testkey_rsa4096.pem",
            "tools/pem/testkey_rsa2048.pem", 
        ]
        
        available_keys = []
        for key_path in key_candidates:
            # Convert to absolute path and normalize path separators
            absolute_key_path = os.path.normpath(os.path.join(self.working_dir, key_path))
            if os.path.exists(absolute_key_path):
                available_keys.append(absolute_key_path)
                print(f"[DETECT] Found private key: {absolute_key_path}")
            else:
                print(f"[DETECT] Private key not found: {absolute_key_path}")
        
        if not available_keys:
            print("[ERROR] No private key files found")
            print("[ERROR] Please ensure private key files exist at:")
            print("  - tools/pem/testkey_rsa4096.pem")
            print("  - tools/pem/testkey_rsa2048.pem")
            sys.exit(1)
        return available_keys
    
    def detect_required_key_type(self, algorithm):
        """Detect required private key type based on algorithm"""
        if algorithm in ["SHA256_RSA4096", "SHA512_RSA4096"]:
            return "4096"
        elif algorithm in ["SHA256_RSA2048", "SHA512_RSA2048"]:
            return "2048"
        else:
            print(f"[ERROR] Unsupported algorithm: {algorithm}")
            sys.exit(1)
    
    def get_key_for_algorithm(self, algorithm):
        """Get suitable private key based on algorithm"""
        required_type = self.detect_required_key_type(algorithm)
        if self.private_key:
            print(f"[INFO] Using manually specified private key: {self.private_key}")
            return self.private_key
        
        for key_path in self.available_keys:
            if f"rsa{required_type}" in key_path:
                print(f"[INFO] Algorithm {algorithm} using private key: {key_path}")
                return key_path
        
        print(f"[ERROR] No private key found matching algorithm {algorithm}")
        sys.exit(1)
    
    def create_backup(self):
        """Backup functionality disabled"""
        print(f"\n=== Backup disabled ===")
        return None
    
    def detect_partition_images(self, exclude_vbmeta=True):
        """Auto-detect partition images in current directory"""
        partition_images = {}
        
        common_partitions = ['boot', 'init_boot']
        
        for partition in common_partitions:
            img_file = f"{partition}.img"
            if os.path.exists(img_file):
                partition_images[partition] = img_file
                print(f"[DETECT] Found partition image: {partition} -> {img_file}")
        return partition_images
    
    def rebuild_partition(self, partition_name, image_path, vbmeta_info, use_original_salt=True):
        """Rebuild single partition"""
        print(f"\n=== Rebuilding partition: {partition_name} ===")
        
        current_info = self.parser.parse_image_info(self.avbtool_path, image_path)
        
        is_chained_partition = False
        chain_algorithm = None
        chain_rollback_index = None
        
        if current_info:
            if current_info.get('algorithm') and current_info['algorithm'] != 'NONE':
                is_chained_partition = True
                chain_algorithm = current_info['algorithm']
                chain_rollback_index = current_info.get('rollback_index', '0')
                print(f"[INFO] Detected chained partition, algorithm: {chain_algorithm}, rollback index: {chain_rollback_index}")
        
        if current_info and current_info.get('image_size'):
            partition_size = int(current_info['image_size'])
            print(f"[INFO] Got partition size from current image: {partition_size} bytes")
        else:
   
            print(f"[ERROR] Unable to get size information for partition {partition_name}")
            return False
        
        if is_chained_partition:
            cmd = [PYTHON_EXECUTABLE, self.avbtool_path, "erase_footer", "--image", image_path]
            self.parser.run_command(cmd, f"Erase AVB footer for {partition_name}")
            
            return self._rebuild_chained_partition(partition_name, image_path, partition_size, 
                                                 chain_algorithm, chain_rollback_index, 
                                                 current_info, use_original_salt)
        else:
            cmd = [PYTHON_EXECUTABLE, self.avbtool_path, "erase_footer", "--image", image_path]
            self.parser.run_command(cmd, f"Erase AVB footer for {partition_name}")
            
            return self._rebuild_hash_partition(partition_name, image_path, partition_size, 
                                              vbmeta_info, current_info, use_original_salt)
    
    def _rebuild_chained_partition(self, partition_name, image_path, partition_size, 
                                  algorithm, rollback_index, current_info, use_original_salt):
        """Rebuild chained partition"""
        print(f"[INFO] Rebuilding chained partition {partition_name}")
        
        hash_desc = None
        props = []
        
        for desc in current_info.get('descriptors', []):
            if desc.get('type') == 'hash' and desc.get('partition_name') == partition_name:
                hash_desc = desc
            elif desc.get('type') == 'prop':
                props.append(desc)
        
        if hash_desc and use_original_salt:
            salt = hash_desc['salt']
            print(f"[INFO] Using original salt: {salt}")
        else:
            salt = None
            print(f"[INFO] Regenerating salt")
        
        suitable_key = self.get_key_for_algorithm(algorithm)
        
        cmd = [
            PYTHON_EXECUTABLE, self.avbtool_path,
            "add_hash_footer",
            "--image", image_path,
            "--partition_name", partition_name,
            "--partition_size", str(partition_size),
            "--algorithm", algorithm,
            "--key", suitable_key,
            "--rollback_index", rollback_index
        ]
        
        if salt and salt != "0" * len(salt):
            cmd.extend(["--salt", salt])
        
        for prop in props:
            if prop.get('key') and prop.get('value'):
                cmd.extend(["--prop", f"{prop['key']}:{prop['value']}"])
                print(f"[INFO] Adding property: {prop['key']} = {prop['value']}")
        
        result = self.parser.run_command(cmd, f"Add signature footer for chained partition {partition_name}")
        
        if result:
            print(f"[SUCCESS] Chained partition {partition_name} rebuilt successfully")
            return True
        else:
            print(f"[ERROR] Chained partition {partition_name} rebuild failed")
            return False
    
    def _rebuild_hash_partition(self, partition_name, image_path, partition_size, 
                               vbmeta_info, current_info, use_original_salt):
        """Rebuild regular hash partition"""
        print(f"[INFO] Rebuilding regular hash partition {partition_name}")
        
        salt = None
        algorithm = "NONE"
        partition_props = []
        
        if current_info and current_info.get('descriptors'):
            for desc in current_info.get('descriptors', []):
                if desc.get('type') == 'hash' and desc.get('partition_name') == partition_name:
                    if use_original_salt:
                        salt = desc.get('salt')
                        algorithm = desc.get('hash_algorithm', 'sha256').upper()
                        if algorithm == 'SHA256':
                            algorithm = 'NONE'
                        print(f"[INFO] Got salt from current image: {salt[:16]}...")
                elif desc.get('type') == 'prop':
                    prop_key = desc.get('key', '')
                    prop_value = desc.get('value', '')
                    partition_props.append(f"{prop_key}:{prop_value}")
                    print(f"[INFO] Found partition property: {prop_key} -> {prop_value}")
        
        if not salt:
            import secrets
            salt = secrets.token_hex(32)  # Generate 64-character hex string
            print(f"[INFO] Generated new salt: {salt[:16]}...")
        
        cmd = [
            PYTHON_EXECUTABLE, self.avbtool_path,
            "add_hash_footer",
            "--image", image_path,
            "--partition_name", partition_name,
            "--partition_size", str(partition_size),
            "--algorithm", algorithm
        ]
        
        # Salt must be specified on Windows
        cmd.extend(["--salt", salt])
        
        # Add prop descriptors
        for prop in partition_props:
            cmd.extend(["--prop", prop])

        result = self.parser.run_command(cmd, f"Add hash footer for regular partition {partition_name}")
        
        if result:
            print(f"[SUCCESS] Regular partition {partition_name} rebuilt successfully")
            return True
        else:
            print(f"[ERROR] Regular partition {partition_name} rebuild failed")
            return False
    
    def rebuild_vbmeta(self, backup_dir, partition_images):
        """Rebuild vbmeta image"""
        print(f"\n=== Rebuilding vbmeta image ===")
        
        original_vbmeta = "vbmeta.img"
        vbmeta_info = self.parser.parse_image_info(self.avbtool_path, original_vbmeta)
        
        if not vbmeta_info:
            print("[ERROR] Unable to parse original vbmeta information")
            return False
        
        vbmeta_algorithm = vbmeta_info.get('algorithm', 'SHA256_RSA4096')
        suitable_key = self.get_key_for_algorithm(vbmeta_algorithm)

        padding_size = "4096"
        
        cmd = [
            PYTHON_EXECUTABLE, self.avbtool_path,
            "make_vbmeta_image",
            "--output", "vbmeta_new.img",
            "--algorithm", vbmeta_algorithm,
            "--key", suitable_key,
            "--rollback_index", vbmeta_info.get('rollback_index', '0'),
            "--flags", vbmeta_info.get('flags', '0'),
            "--rollback_index_location", "0",
            "--padding_size", str(padding_size)
        ]
        
        # Preserve original vbmeta descriptors
        cmd.extend(["--include_descriptors_from_image", original_vbmeta])
        
        for partition_name, image_path in partition_images.items():
            if os.path.exists(image_path):
                cmd.extend(["--include_descriptors_from_image", image_path])
        
        result = self.parser.run_command(cmd, "Generate new vbmeta image")
        
        if result and os.path.exists("vbmeta_new.img"):
            shutil.move("vbmeta_new.img", "vbmeta.img")
            print("[SUCCESS] vbmeta.img rebuilt successfully")
            return True
        else:
            print("[ERROR] vbmeta.img rebuild failed")
            return False
    
    def verify_result(self):
        """Verify rebuild results"""
        print(f"\n=== Verifying rebuild results ===")
        
        if os.path.exists("vbmeta.img"):
            print("\n[VERIFY] New vbmeta.img:")
            self.parser.parse_image_info(self.avbtool_path, "vbmeta.img")
        else:
            print("\n[INFO] vbmeta.img not found (possibly pure chained partition mode)")
        
        partition_images = self.detect_partition_images()
        for partition_name, image_path in partition_images.items():
            print(f"\n[VERIFY] {partition_name}.img:")
            self.parser.parse_image_info(self.avbtool_path, image_path)
    
    def rebuild_all(self, partitions=None, use_original_salt=True, chained_mode=False):
        """Execute complete rebuild process"""
        print("=== AVB rebuild started ===")
        
        if chained_mode:
            print("[INFO] Chained partition mode enabled")
        
        backup_dir = self.create_backup()
        
        if partitions:
            partition_images = {}
            for partition in partitions:
                img_file = f"{partition}.img" if not partition.endswith('.img') else partition
                if os.path.exists(img_file):
                    partition_name = img_file.replace('.img', '')
                    partition_images[partition_name] = img_file
                    print(f"[SPECIFIED] Using partition image: {partition_name} -> {img_file}")
                else:
                    print(f"[WARNING] Specified partition image does not exist: {img_file}")
        else:
            partition_images = self.detect_partition_images()
        
        if not partition_images:
            print("[ERROR] No partition image files detected")
            return False
        
        chained_partitions = []
        regular_partitions = []
        
        for partition_name, image_path in partition_images.items():
            current_info = self.parser.parse_image_info(self.avbtool_path, image_path)
            if current_info and current_info.get('algorithm') and current_info['algorithm'] != 'NONE':
                chained_partitions.append((partition_name, image_path))
                print(f"[INFO] {partition_name} is a chained partition")
            else:
                regular_partitions.append((partition_name, image_path))
                print(f"[INFO] {partition_name} is a regular partition")
        
        if chained_mode:
            if regular_partitions:
                print(f"[WARNING] Found regular partitions in chained partition mode: {[p[0] for p in regular_partitions]}")
                print("[WARNING] These regular partitions will be skipped due to missing vbmeta.img")
                partition_images = dict(chained_partitions)
                regular_partitions = []
            
            if not chained_partitions:
                print("[ERROR] No chained partitions found in chained partition mode")
                return False
        else:
            if regular_partitions:
                original_vbmeta = os.path.join("vbmeta.img")
                if not os.path.exists(original_vbmeta):
                    print("[ERROR] Found regular partitions but missing vbmeta.img")
                    print("[TIP] Use --chained-mode option to process only chained partitions")
                    return False

        success_count = 0
        for partition_name, image_path in chained_partitions:
            if self.rebuild_partition(partition_name, image_path, {'descriptors': []}, use_original_salt):
                success_count += 1
        
        if regular_partitions and not chained_mode:
            # Parse original vbmeta information
            original_vbmeta = os.path.join("vbmeta.img")
            vbmeta_info = self.parser.parse_image_info(self.avbtool_path, original_vbmeta)
            
            for partition_name, image_path in regular_partitions:
                if self.rebuild_partition(partition_name, image_path, vbmeta_info, use_original_salt):
                    success_count += 1

            if regular_partitions:
                regular_partition_dict = dict(regular_partitions)
                if not self.rebuild_vbmeta(backup_dir, regular_partition_dict):
                    print("[WARNING] vbmeta rebuild failed, but chained partitions may have been successfully rebuilt")
        
        if success_count == 0:
            print("[ERROR] No partitions were successfully rebuilt")
            return False
        
        self.verify_result()
        
        print(f"\n=== Rebuild completed ===")
        print(f"Successfully rebuilt {success_count} partitions")
        if chained_mode:
            print("Chained partition mode: Only processed independently verified partitions")
        elif regular_partitions:
            print("vbmeta.img generated successfully")
        return True

def main():
    """Main function"""
    parser = argparse.ArgumentParser(description='AVB Universal Intelligent Rebuild Script')
    parser.add_argument('--partitions', '-p', nargs='+', 
                       help='Specify list of partitions to rebuild, e.g.: boot init_boot vendor_boot')
    parser.add_argument('--working-dir', '-w', 
                       help='Working directory path')
    parser.add_argument('--avbtool', '-a', 
                       help='avbtool.py file path')
    parser.add_argument('--private-key', '-k', 
                       help='Private key file path (auto-detect if not specified)')
    parser.add_argument('--regenerate-salt', '-r', action='store_true',
                       help='Regenerate salt instead of using original salt')
    parser.add_argument('--verify-only', '-v', action='store_true',
                       help='Only verify existing images, do not rebuild')
    parser.add_argument('--chained-mode', '-c', action='store_true',
                       help='Chained partition mode, allow skipping vbmeta.img (only process independently signed partitions)')
    
    args = parser.parse_args()
    
    working_dir = args.working_dir or os.getcwd()
    avbtool_path = args.avbtool or os.path.join(working_dir, "tools", "avbtool.py")
    
    required_files = [avbtool_path]
    missing_files = [f for f in required_files if not os.path.exists(f)]

    vbmeta_required = True
    if args.chained_mode:
        vbmeta_required = False
        print("[INFO] Chained partition mode enabled, will skip vbmeta.img check")
    elif not args.verify_only:
        # Non-chained mode and not verify-only mode, requires vbmeta.img
        if not os.path.exists("vbmeta.img"):
            missing_files.append("vbmeta.img")
    
    if not args.verify_only:
        has_partition_images = False
        if args.partitions:
            for partition in args.partitions:
                img_file = f"{partition}.img" if not partition.endswith('.img') else partition
                if os.path.exists(img_file):
                    has_partition_images = True
                    break
        else:
            for file in os.listdir('.'):
                if file.endswith('.img') and file != 'vbmeta.img':
                    has_partition_images = True
                    break
        
        if not has_partition_images:
            missing_files.append("partition image files (e.g. boot.img)")
    
    if missing_files and not args.verify_only:
        print(f"[ERROR] Missing required files: {', '.join(missing_files)}")
        if not args.chained_mode and "vbmeta.img" in missing_files:
            print("[INFO] Use --chained-mode option to skip vbmeta.img if only processing chained partitions")
        return False
    
    rebuilder = AvbRebuilder(working_dir, avbtool_path, args.private_key)
    
    if args.verify_only:
        rebuilder.verify_result()
        return True
    else:
        return rebuilder.rebuild_all(args.partitions, not args.regenerate_salt, args.chained_mode)

if __name__ == "__main__":
    success = main()

    sys.exit(0 if success else 1)
