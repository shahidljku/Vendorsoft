import * as fs from 'fs';
import * as path from 'path';

/**
 * Phase 9: Firestore Offline Migration Runner
 * 
 * Executes idempotent, versioned data migrations against Firestore.
 * This runner is strictly executed MANUALLY (or via a separate pipeline) 
 * POST-deployment, ensuring application rollout is decoupled from slow data evolution.
 * 
 * Usage:
 * npx ts-node tools/migrations/runner.ts --env production
 */

async function main() {
  console.log('--- VendSoft Firestore Migration Runner ---');
  const envArg = process.argv.includes('--env') ? process.argv[process.argv.indexOf('--env') + 1] : 'staging';
  console.log(`Target Environment: ${envArg}`);

  const migrationsDir = path.join(__dirname);
  const files = fs.readdirSync(migrationsDir).filter(f => f.match(/^\d{3}_.*\.ts$/)).sort();

  for (const file of files) {
    console.log(`\n[Execution] Starting migration: ${file}`);
    try {
      const migration = require(path.join(migrationsDir, file));
      
      // Every migration must expose an `up()` function that is strictly idempotent
      if (typeof migration.up === 'function') {
        // Run migration. The framework expects the migration to log its own progress, 
        // handle cursors for resumability, and catch partial failures.
        await migration.up(envArg);
        console.log(`[Success] Migration completed: ${file}`);
      } else {
        console.log(`[Skip] No up() function found in ${file}`);
      }
    } catch (err) {
      console.error(`[FATAL] Migration failed: ${file}`, err);
      process.exit(1); // Stop execution on first failure to prevent data corruption
    }
  }

  console.log('\n--- All migrations completed successfully ---');
}

if (require.main === module) {
  main().catch(console.error);
}
