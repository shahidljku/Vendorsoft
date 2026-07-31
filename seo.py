import os
import re

directory = r'e:\image_sender\website'

html_files = [f for f in os.listdir(directory) if f.endswith('.html')]

metadata_template = '''
  <!-- Standard SEO Metadata -->
  <meta name="theme-color" content="#0D1117">
  <meta name="color-scheme" content="dark">
  <meta name="application-name" content="VendorPro">
  
  <!-- Open Graph -->
  <meta property="og:type" content="website">
  <meta property="og:image" content="https://vendorpro.pages.dev/images/app-icon.png">
  <meta property="og:site_name" content="VendorPro">
  <meta property="og:locale" content="en_IN">

  <!-- Twitter -->
  <meta name="twitter:card" content="summary">
  <meta name="twitter:image" content="https://vendorpro.pages.dev/images/app-icon.png">
  <meta name="twitter:creator" content="@VendorPro">
  <meta name="twitter:site" content="@VendorPro">

  <!-- Favicons and Web App Manifest -->
  <link rel="apple-touch-icon" sizes="180x180" href="/images/app-icon.png">
  <link rel="icon" type="image/png" sizes="32x32" href="/images/app-icon.png">
  <link rel="icon" type="image/png" sizes="16x16" href="/images/app-icon.png">
  <link rel="manifest" href="/site.webmanifest">
  <meta name="msapplication-TileColor" content="#00E676">
  <meta name="msapplication-config" content="/browserconfig.xml">
  <meta name="apple-mobile-web-app-title" content="VendorPro">
'''

for file in html_files:
    path = os.path.join(directory, file)
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()

    if 'site.webmanifest' in content:
        continue

    url = f'https://vendorpro.pages.dev/{file}'
    if file == 'index.html':
        url = 'https://vendorpro.pages.dev/'

    title_match = re.search(r'<title>(.*?)</title>', content, re.IGNORECASE)
    desc_match = re.search(r'<meta name="description" content="(.*?)"', content, re.IGNORECASE)
    
    title = title_match.group(1) if title_match else 'VendorPro'
    desc = desc_match.group(1) if desc_match else 'Billing Software for Newspaper Vendors'

    page_specific_meta = f'''
  <link rel="canonical" href="{url}">
  <meta property="og:url" content="{url}">
  <meta property="og:title" content="{title}">
  <meta property="og:description" content="{desc}">
  <meta name="twitter:title" content="{title}">
  <meta name="twitter:description" content="{desc}">
'''

    full_meta = page_specific_meta + metadata_template

    content = content.replace('</head>', full_meta + '</head>')
    
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f'Updated {file}')
