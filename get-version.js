const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ['--disable-blink-features=AutomationControlled']
  });
  const context = await browser.newContext({
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    acceptDownloads: true
  });
  const page = await context.newPage();

  try {
    console.error('Navigating to redirect URL...');

    // Set up download handler to capture the download URL
    const downloadPromise = page.waitForEvent('download', { timeout: 30000 });

    // Navigate - this will trigger a download
    page.goto('https://claude.ai/api/desktop/darwin/universal/dmg/latest/redirect').catch(() => {});

    // Wait for the download to start and get the URL
    const download = await downloadPromise;
    const downloadUrl = download.url();
    console.error('Download URL captured: ' + downloadUrl);

    // Cancel the download - we only need the URL
    await download.cancel();

    // Output the URL (this is what we grep for)
    console.log(downloadUrl);

  } catch (error) {
    console.error('Error:', error.message);

    // If download event times out, try checking response headers
    console.error('Trying alternative method...');
    try {
      const response = await page.goto(
        'https://claude.ai/api/desktop/darwin/universal/dmg/latest/redirect',
        { waitUntil: 'commit', timeout: 30000 }
      );
      const headers = response?.headers();
      if (headers?.location) {
        console.log(headers.location);
      }
    } catch (e) {
      console.error('Alternative method also failed:', e.message);
    }
    process.exit(1);
  } finally {
    await browser.close();
  }
})();
