/*
Copyright 2023 The Cockroach Authors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"flag"

	"context"
	"os"
	"path/filepath"

	crdbv1alpha1 "github.com/cockroachdb/cockroach-operator/apis/v1alpha1"
	"github.com/cockroachdb/cockroach-operator/pkg/controller"
	"github.com/cockroachdb/cockroach-operator/pkg/resource"
	"github.com/cockroachdb/cockroach-operator/pkg/security"
	"github.com/cockroachdb/cockroach-operator/pkg/utilfeature"
	"github.com/cockroachdb/errors"
	"github.com/go-logr/logr"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	_ "k8s.io/client-go/plugin/pkg/client/auth/gcp"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	server "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	webhook "sigs.k8s.io/controller-runtime/pkg/webhook"
)

const (
	certDir                 = "/tmp/k8s-webhook-server/serving-certs"
	defaultLeaderElectionID = "crdb-operator.cockroachlabs.com"
	watchNamespaceEnvVar    = "WATCH_NAMESPACE"
)

var (
	scheme   = runtime.NewScheme()
	setupLog = ctrl.Log.WithName("setup")
)

func init() {
	_ = clientgoscheme.AddToScheme(scheme)
	_ = crdbv1alpha1.AddToScheme(scheme)
}

// SetupWebhookTLS ensures that the webhook TLS secret exists, the necesary files are in place, and that the webhook
// client configuration has the correct CABundle for TLS. This should be called before starting the controller manager
// to ensure everything is in place at startup.
//
// Certificate rotation is as simple as deleting the pod and letting the deployment start a new one. If you're using
// your own certificates, be sure to update them before deleting the pod.
func SetupWebhookTLS(ctx context.Context, ns, dir string) error {
	cfg, err := ctrl.GetConfig()
	if err != nil {
		return errors.Wrap(err, "failed to get REST config")
	}

	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		return errors.Wrap(err, "failed to create client set")
	}

	webhookAPI := cs.AdmissionregistrationV1()
	secretsAPI := cs.CoreV1().Secrets(ns)

	// we create a new cert on each startup
	cert, err := resource.CreateWebhookCertificate(ctx, secretsAPI, ns)
	if err != nil {
		return errors.Wrap(err, "failed find or create webhook certificate")
	}

	// write them out
	if err := writeWebhookSecrets(cert, dir); err != nil {
		return errors.Wrap(err, "failed to write webhook certificate to disk")
	}

	ca, err := resource.FindOrCreateWebhookCA(ctx, secretsAPI)
	if err != nil {
		return errors.Wrap(err, "failed to find webhook CA certificate")
	}

	if err := resource.PatchMutatingWebhookConfig(ctx, webhookAPI.MutatingWebhookConfigurations(), ca); err != nil {
		return errors.Wrap(err, "failed to patch mutating webhook")
	}

	if err := resource.PatchValidatingWebhookConfig(ctx, webhookAPI.ValidatingWebhookConfigurations(), ca); err != nil {
		return errors.Wrap(err, "failed to patch validating webhook")
	}

	return nil
}

func writeWebhookSecrets(cert security.Certificate, dir string) error {
	if err := os.MkdirAll(dir, os.ModePerm); err != nil {
		return errors.Wrap(err, "failed to create certs directory")
	}

	// r/w for current user only
	mode := os.FileMode(0600)

	if err := os.WriteFile(filepath.Join(dir, "tls.crt"), cert.Certificate(), mode); err != nil {
		return errors.Wrap(err, "failed to write TLS certificate")
	}

	return errors.Wrap(
		os.WriteFile(filepath.Join(dir, "tls.key"), cert.PrivateKey(), mode),
		"failed to write TLS private key",
	)
}

func main() {
	var metricsAddr, featureGatesString, leaderElectionID string
	var enableLeaderElection, skipWebhookConfig bool

	// use zap logging cli options
	opts := zap.Options{}
	opts.BindFlags(flag.CommandLine)

	flag.StringVar(&metricsAddr, "metrics-addr", ":8080", "The address the metric endpoint binds to.")
	flag.StringVar(&featureGatesString, "feature-gates", "", "Feature gate to enable, format is a command separated list enabling features, for instance RunAsNonRoot=false")
	flag.StringVar(&leaderElectionID, "leader-election-id", defaultLeaderElectionID, "The ID to use for leader election")
	flag.BoolVar(&enableLeaderElection, "enable-leader-election", false,
		"Enable leader election for controller manager. Enabling this will ensure there is only one active controller manager.")
	flag.BoolVar(&skipWebhookConfig, "skip-webhook-config", false,
		"When set, don't setup webhook TLS certificates. Useful in OpenShift where this step is handled already.")
	flag.Parse()

	// create logger using zap cli options
	// for instance --zap-log-level=debug
	logger := zap.New(zap.UseFlagOptions(&opts))
	ctrl.SetLogger(logger)

	// If features gates are passed to the command line, use it (otherwise use featureGates from configuration)
	if featureGatesString != "" {
		if err := utilfeature.DefaultMutableFeatureGate.Set(featureGatesString); err != nil {
			setupLog.Error(err, "unable to parse feature-gates flag")
			os.Exit(1)
		}
	}

	// Namespaces that are managed. Can be one of:
	//   (empty) - Watch all namespaces
	//   ns1 - Watch one watchNamespace
	//   ns1,ns2 - Watch multiple namespaces
	// See:
	// https://sdk.operatorframework.io/docs/building-operators/golang/operator-scope/#configuring-watch-namespaces-dynamically
	// watchNamespace := os.Getenv(watchNamespaceEnvVar)
	webhookServer := webhook.NewServer(webhook.Options{Port: 9443, CertDir: certDir})
	mgrOpts := ctrl.Options{
		Scheme:           scheme,
		Metrics:          server.Options{BindAddress: metricsAddr},
		LeaderElection:   enableLeaderElection,
		LeaderElectionID: leaderElectionID,
		WebhookServer:    webhookServer,
	}

	// if strings.Contains(watchNamespace, ",") {
	// 	setupLog.Info("manager set up with multiple namespaces", "namespaces", watchNamespace)
	// 	mgrOpts.Namespace = ""
	// 	mgrOpts.NewCache = cache.MultiNamespacedCacheBuilder(strings.Split(watchNamespace, ","))
	// }

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), mgrOpts)
	if err != nil {
		setupLog.Error(err, "unable to create manager")
		os.Exit(1)
	}

	if err := (&crdbv1alpha1.CrdbCluster{}).SetupWebhookWithManager(mgr); err != nil {
		setupLog.Error(err, "unable to setup webhook")
		os.Exit(1)
	}

	reconciler := controller.InitClusterReconciler()
	if err = reconciler(mgr); err != nil {
		setupLog.Error(err, "unable to create controller", "controller", "CrdbCluster")
		os.Exit(1)
	}

	// add a logger to the main context
	ctx := logr.NewContext(ctrl.SetupSignalHandler(), logger)

	if !skipWebhookConfig {
		// ensure TLS is all set up for webhooks
		if err := SetupWebhookTLS(ctx, os.Getenv("NAMESPACE"), certDir); err != nil {
			setupLog.Error(err, "failed to setup TLS")
			os.Exit(1)
		}
	}

	setupLog.Info("starting manager")
	if err := mgr.Start(ctx); err != nil {
		setupLog.Error(err, "problem running manager")
		os.Exit(1)
	}
}
