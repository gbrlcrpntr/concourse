import test from 'ava';
import Suite from '../helpers/suite.js';

import color from 'color';
import palette from '../helpers/palette.js';

test.beforeEach(async t => {
  t.context = new Suite();
  await t.context.init(t);
});

test.afterEach(async t => {
  t.context.passed(t);
});

test.afterEach.always(async t => {
  await t.context.finish(t);
});

test('shows abort hooks', async t => {
  await t.context.fly.run('set-pipeline -n -p some-pipeline -c fixtures/hooks-pipeline.yml');
  await t.context.fly.run('unpause-pipeline -p some-pipeline');

  await t.context.fly.run('trigger-job -j some-pipeline/on_abort');

  await t.context.web.page.goto(t.context.web.route(`/teams/${t.context.teamName}/pipelines/some-pipeline/jobs/on_abort/builds/1`));
  await t.context.web.page.setViewport({width: 1200, height: 900});

  await t.context.web.waitForText("say-bye-from-step");
  await t.context.web.waitForText("say-bye-from-job");

  await t.context.web.page.waitForSelector('button[aria-label="Abort Build"]');
  await t.context.web.page.click('button[aria-label="Abort Build"]');

  await t.context.web.waitForBackgroundColor('.build-header', palette.brown, {
    timeout: 60000,
  });
  await t.context.web.page.waitForSelector('[data-step-name="say-bye-from-step"] [data-step-state="succeeded"]');
  await t.context.web.page.waitForSelector('[data-step-name="say-bye-from-job"] [data-step-state="succeeded"]');

  await t.context.web.clickAndWait('[data-step-name="say-bye-from-step"] .header', '[data-step-name="say-bye-from-step"] .step-body:not(.step-collapsed)');
  t.regex(await t.context.web.text(), /bye from step/);

  await t.context.web.clickAndWait('[data-step-name="say-bye-from-job"] .header', '[data-step-name="say-bye-from-job"] .step-body:not(.step-collapsed)');
  t.regex(await t.context.web.text(), /bye from job/);
});

test('can be switched between', async t => {
  await t.context.fly.run('set-pipeline -n -p some-pipeline -c fixtures/states-pipeline.yml');
  await t.context.fly.run('unpause-pipeline -p some-pipeline');

  await t.context.fly.run('trigger-job -w -j some-pipeline/passing');
  await t.context.fly.run('trigger-job -w -j some-pipeline/passing');

  await t.context.web.page.goto(t.context.web.route(`/teams/${t.context.teamName}/pipelines/some-pipeline/jobs/passing/builds/1`));

  await t.context.web.clickAndWait('#builds li:nth-child(1) a', '[data-build-name="2"]');
  t.regex(await t.context.web.text(), /passing#2/);

  await t.context.web.clickAndWait('#builds li:nth-child(2) a', '[data-build-name="1"]');
  t.regex(await t.context.web.text(), /passing#1/);
});

test('triggers a job through the typed vars form', async t => {
  await t.context.fly.run('set-pipeline -n -p some-pipeline -c fixtures/job-vars.yml');
  await t.context.fly.run('unpause-pipeline -p some-pipeline');

  await t.context.web.page.goto(t.context.web.route(
    `/teams/${t.context.teamName}/pipelines/some-pipeline/jobs/parameterized`,
  ));
  await t.context.web.clickAndWait('#trigger-build-button', '#trigger-build-form');

  t.regex(await t.context.web.text(), /Do not enter secrets/);
  t.is(
    await t.context.web.page.$eval('#trigger-build-form-var-branch', element => element.value),
    'main',
  );
  t.is(
    await t.context.web.page.$eval('#trigger-build-form-var-count', element => element.value),
    '1',
  );

  await t.context.web.page.click('#trigger-build-form-var-branch', {clickCount: 3});
  await t.context.web.page.type('#trigger-build-form-var-branch', 'feature-x');
  await t.context.web.page.click('#trigger-build-form-var-count', {clickCount: 3});
  await t.context.web.page.type('#trigger-build-form-var-count', '3');
  await t.context.web.page.click('#trigger-build-form-var-dry_run');
  await t.context.web.page.select('#trigger-build-form-var-deploy_env', 'prod');
  await t.context.web.clickAndWait('#trigger-build-form-submit', '[data-build-name="1"]');

  await t.context.web.clickAndWait(
    '[data-step-name="echo-vars"] .header',
    '[data-step-name="echo-vars"] .step-body:not(.step-collapsed)',
  );
  await t.context.web.waitForText('branch=feature-x');

  const pageText = await t.context.web.text();
  t.regex(pageText, /branch=feature-x/);
  t.regex(pageText, /count=3/);
  t.regex(pageText, /dry_run=true/);
  t.regex(pageText, /deploy_env=prod/);
});
