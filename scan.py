import os
import re

html_files = [f for f in os.listdir(r'e:\image_sender\website') if f.endswith('.html')]
for file in html_files:
    with open(os.path.join(r'e:\image_sender\website', file), 'r', encoding='utf-8') as f:
        content = f.read()
        
        imgs = re.findall(r'<img[^>]*>', content)
        for img in imgs:
            if 'alt=' not in img:
                print(f'Missing alt in {file}: {img}')
            if 'loading=' not in img and 'class="nav__logo"' not in img:
                print(f'Missing lazy load in {file}: {img}')

        links = re.findall(r'<a [^>]*>.*?</a>', content, re.DOTALL)
        for link in links:
            if '<svg' in link and 'aria-label=' not in link:
                print(f'Potential missing aria-label in {file}: {link.strip()[:50]}')
