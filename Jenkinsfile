//
// Plugin "build user vars" is needed!
// Set "Manage Jenkins -> Configure System -> Global properties" "DEFAULT_EMAIL" Environment variable for users without email address!
//


// github commit status
void setBuildStatus(String message, String state) {
	step([
		$class: 'GitHubCommitStatusSetter',
		reposSource: [$class: 'ManuallyEnteredRepositorySource', url: 'https://github.com/lapicidae/vdr-server'],
		contextSource: [$class: 'ManuallyEnteredCommitContextSource', context: 'ci/jenkins/build-status'],
		errorHandlers: [[$class: 'ChangingBuildStatusErrorHandler', result: 'UNSTABLE']],
		statusResultSource: [ $class: 'ConditionalStatusResultSource', results: [[$class: 'AnyBuildResult', message: message, state: state]] ]
	]);
}


pipeline {
	environment {
		registry = "lapicidae/vdr-server"
		registryCredential = 'dockerhub'
		registryTag = 'latest'
		//gitURL = 'https://github.com/lapicidae/vdr-server.git'
		currTime = sh(returnStdout: true, script: 'date +"%H:%M"').trim()
		currDate = sh(returnStdout: true, script: 'date +"%m.%d.%Y"').trim()
		dockerImage = ''
		email = ''
	}
	agent any
	stages {
		stage('Init') {
			steps{
				echo 'Initializing....'
				script {
					user = wrap([$class: 'BuildUser']) { return env.BUILD_USER }
					user_id = wrap([$class: 'BuildUser']) { return env.BUILD_USER_ID }
					email = wrap([$class: 'BuildUser']) { return env.BUILD_USER_EMAIL }
					if (!email?.trim()) {
						email = "${DEFAULT_EMAIL}"
					}
				}
				echo "--- User Info ---\nUser:\t\t$user\nUser ID:\t$user_id\neMail:\t\t$email\nTime:\t\t$currTime\nDate:\t\t$currDate"
			}
		}
		stage('Clone') {
			steps{
				echo 'Cloning....'
				checkout scm
				//git gitURL
			}
		}
		stage('Build') {
			steps{
				echo 'Building....'
				script {
					dockerImage = docker.build("${registry}:${BUILD_NUMBER}", '--no-cache --rm .')
				}
			}
		}
		stage('Version') {
			steps{
				echo 'Read Version from image....'
				script {
					VERSION = sh(returnStdout: true, script: 'docker run --rm --entrypoint "" $registry:$BUILD_NUMBER cat /vdr/VERSION').trim()
				}
				echo "Image Version: $VERSION"
			}
		}
		stage('Publish') {
			steps{
				echo 'Publishing....'
				script {
					docker.withRegistry( '', registryCredential ) {
						dockerImage.push("${VERSION}")
						dockerImage.push(registryTag)
					}
				}
			}
		}
		stage('Clean') {
			steps{
				echo 'Cleaning....'
				sh "docker rmi $registry:$BUILD_NUMBER || echo Failed to remove image $registry:$BUILD_NUMBER."
				sh "docker rmi $registry:$registryTag || echo Failed to remove image $registry:$registryTag."
			}
		}
	}
	post {
		always {
			echo "Build result => ${currentBuild.result}"
			mail to: "$email",
			  subject: "Pipeline: ${currentBuild.fullDisplayName} -> ${currentBuild.result}",
			  charset: 'UTF-8',
			  mimeType: 'text/html',
			  body: "<b>${env.JOB_NAME} - Build #${env.BUILD_NUMBER} - <em>${currentBuild.result}</em></b><br/><br/>Job started by user ${user_id} (${user}) at ${currTime} on ${currDate}.<br/>Build took ${currentBuild.durationString}.<br/><br/>Check console <a href='${env.BUILD_URL}console'>output</a> to view full results.<br/><br/>Your faithful employee<br/><em>Node</em> ${env.NODE_NAME}"
		}
		success {
			setBuildStatus('Build succeeded', 'SUCCESS');
		}
		failure {
			setBuildStatus('Build failed', 'FAILURE');
		}
	}
}
